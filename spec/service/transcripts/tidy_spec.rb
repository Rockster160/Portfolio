require "rails_helper"

# A recording typed up by a machine that heard the sounds and guessed at the
# words. The guesses are wrong exactly where the recording is worth having -
# "hand coating everything now" came out of half an hour about writing
# software - and the one thing that must not happen while they are put right
# is the sentences being rewritten into better ones.
RSpec.describe Transcripts::Tidy do
  let(:user) { User.me }
  let(:job) { user.job_applications.create!(company: "Podium", role: "Staff Engineer") }

  # What each call was actually asked. A window carries the tail of the one
  # before it, and reading the prompt is the only way to say that it did.
  def asked = (@asked ||= [])

  def model_says(*texts)
    queue = texts.dup
    allow_any_instance_of(Buddy::GPT::Client).to receive(:stream) { |_client, args|
      asked << args[:instructions].to_s
      {
        ok:    true,
        text:  (queue.length > 1 ? queue.shift : queue.first),
        model: "gpt-5.4-mini",
        usage: FakeBuddyClient::DEFAULT_USAGE,
      }
    }
  end

  def fixes(*found)
    { fixes: found }.to_json
  end

  def transcript!(*texts)
    job.transcripts.create!(
      title:    "Hiring manager",
      speakers: { "Me" => { "name" => "Rocco", "me" => true }, "Them" => { "name" => "Them" } },
      turns:    texts.each_with_index.map { |text, index|
        {
          "raw"     => "Unknown",
          "speaker" => index.even? ? "Them" : "Me",
          "at"      => index * 10.0,
          "to"      => (index * 10.0) + 8,
          "text"    => text,
        }
      },
    )
  end

  describe "a word the recorder misheard" do
    subject(:transcript) {
      transcript!(
        "How are you writing it these days?",
        "I'm hand coating everything now, and it is faster than it sounds.",
      )
    }

    it "puts it right and keeps what the recorder wrote" do
      model_says(fixes({ turn: 2, was: "hand coating", now: "hand coding" }))

      result = described_class.call(transcript)

      expect(result.ok).to be(true)
      expect(result.mended).to eq(1)
      expect(transcript.reload.turns[1]["text"]).to start_with("I'm hand coding everything now")
      expect(transcript.turns[1]["heard"]).to include("hand coating")
    end

    it "leaves the rest of the sentence exactly as it was said" do
      model_says(fixes({ turn: 2, was: "hand coating", now: "hand coding" }))

      described_class.call(transcript)

      expect(transcript.reload.turns[1]["text"])
        .to eq("I'm hand coding everything now, and it is faster than it sounds.")
    end

    it "marks the recording as gone over, so the next pass is asked for" do
      model_says(fixes)

      expect { described_class.call(transcript) }
        .to change { transcript.reload.tidied_at }.from(nil)

      expect(described_class.call(transcript).error).to eq(:done)
      expect(described_class.call(transcript, again: true).ok).to be(true)
    end
  end

  # The guard, and the whole reason the reply is a list of replacements rather
  # than the text: a sentence is a thing somebody said out loud, and a better
  # one in its place is a thing he will later believe he said.
  describe "a reply that is an edit rather than a mishearing" do
    subject(:transcript) {
      transcript!(
        "Tell me about the mail one.",
        "So we, um, we had four inboxes and I, I pulled them into one place.",
      )
    }

    it "refuses a replacement that rewrites the sentence" do
      rewritten = {
        turn: 2,
        was:  "So we, um, we had four inboxes",
        now:  "We consolidated four inboxes",
      }
      model_says(fixes(rewritten))

      result = described_class.call(transcript)

      expect(result.mended).to eq(0)
      expect(transcript.reload.turns[1]["text"]).to include("So we, um, we had four inboxes")
      expect(transcript.turns[1]["heard"]).to be_nil
    end

    it "refuses a replacement for words that are not in the turn it names" do
      model_says(fixes({ turn: 1, was: "four inboxes", now: "four mailboxes" }))

      expect(described_class.call(transcript).mended).to eq(0)
      expect(transcript.reload.turns[1]["text"]).to include("four inboxes")
    end

    it "refuses a replacement in a turn the window never covered" do
      model_says(fixes({ turn: 9, was: "four inboxes", now: "four mailboxes" }))

      expect(described_class.call(transcript).mended).to eq(0)
      expect(transcript.reload.turns[1]["text"]).to include("four inboxes")
    end
  end

  describe "a call that came back with nothing readable in it" do
    subject(:transcript) { transcript!("A word.", "Another word.") }

    it "leaves the recording alone rather than marking it gone over" do
      model_says("I could not read that file.")

      result = described_class.call(transcript)

      expect(result.ok).to be(false)
      expect(result.error).to eq(:unreadable)
      expect(transcript.reload.tidied_at).to be_nil
    end
  end

  # A window that opens cold has nothing above its first sentence to place a
  # word from, and the first sentences of a window are where the terms of the
  # conversation get settled.
  describe "a recording longer than one window" do
    subject(:transcript) {
      transcript!("#{"filler words and more of them. " * 230}We ran it on Sidekiq.", "Say more.")
    }

    it "reads it in windows and hands each one the end of the last" do
      model_says(fixes)

      described_class.call(transcript)

      expect(asked.length).to eq(2)
      expect(asked.last).to include("WHAT WAS SAID JUST BEFORE THIS STRETCH")
      expect(asked.last).to include("We ran it on Sidekiq.")
      expect(asked.first).not_to include("WHAT WAS SAID JUST BEFORE THIS STRETCH")
    end
  end

  describe "the prompt" do
    subject(:transcript) {
      transcript!("What have you built?", "A mail consolidation, four inboxes into one.")
    }

    it "says who was talking on each line, and what the conversation is" do
      model_says(fixes)

      described_class.call(transcript)

      expect(asked.first).to include("1. [Them] What have you built?")
      expect(asked.first).to include("2. [the candidate] A mail consolidation")
      expect(asked.first).to include("The company interviewing them is Podium.")
    end
  end
end
