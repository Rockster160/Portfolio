require "rails_helper"

# The readable version of a conversation, written beside the spoken one.
#
# This is the only pass allowed to change the words, so the examples here are
# mostly about what it REFUSES. The failure that matters is not a bad cleaning,
# it is a good rewrite: a model asked to clean up a spoken answer will tighten
# the argument and hand back the answer he wishes he had given, and that
# version reads perfectly and is worth nothing - he cannot practise it, and he
# would later believe he had been that fluent in the room.
RSpec.describe Transcripts::Clean do
  let(:user) { User.me }
  let(:job) { user.job_applications.create!(company: "Podium", role: "Staff Engineer") }

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

  def asked = (@asked ||= [])

  def cleans(*found)
    model_says({ clean: found }.to_json)
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

  # The answer he actually gave, with the noise in it. Long enough to be past
  # SHORT_TURN, because that is where the guards apply.
  def said
    "Um, so, so the agent now, it's, it's almost entirely self-sufficient " \
      "at this point. Um, obviously with with guidance from me. But, um, what " \
      "really happens is there is an internal chat with a Claude agent. We " \
      "call it Coco, and the agents can ask questions from it."
  end

  describe "the noise taken out" do
    subject(:transcript) { transcript!("How does that run day to day?", said) }

    it "writes the cleaned version beside what was said and leaves the words alone" do
      cleans(
        { turn: 1, text: "How does that run day to day?" },
        { turn: 2, text: "So the agent now is almost entirely self-sufficient at " \
                         "this point, with guidance from me. But what happens is " \
                         "there is an internal chat with a Claude agent. We call " \
                         "it Coco, and the agents can ask questions from it." },
      )

      result = described_class.call(transcript)
      transcript.reload

      expect(result.ok).to be(true)
      expect(result.cleaned).to eq(1)
      expect(transcript.turns[1]["text"]).to eq(said)
      expect(transcript.turns[1]["clean"]).to start_with("So the agent now is almost")
      expect(transcript.cleaned_at).to be_present
    end

    # An unchanged turn is not stored twice. The page falls back to what was
    # said wherever there is no cleaned version, so a copy would only make the
    # row bigger and tell a reader nothing.
    it "keeps nothing for a turn that came back exactly as it was said" do
      cleans(
        { turn: 1, text: "How does that run day to day?" },
        { turn: 2, text: said },
      )

      described_class.call(transcript)

      expect(transcript.reload.turns.map { |turn| turn.key?("clean") }).to eq([false, false])
    end
  end

  describe "what it refuses" do
    subject(:transcript) { transcript!("How does that run day to day?", said) }

    # By the turn number the model answers with, which is counted from one.
    def clean_of(number) = transcript.reload.turns[number - 1]["clean"]

    # THE EXPENSIVE ONE. Every word of this is true, it reads better than what
    # he said, and it is half the length - so it is a summary of his answer and
    # not his answer.
    it "refuses a summary, however well written" do
      cleans({ turn: 2, text: "The agent is self-sufficient now." })

      expect(described_class.call(transcript).cleaned).to eq(0)
      expect(clean_of(2)).to be_nil
    end

    # Same length, different words: the sentence was rebuilt rather than
    # cleaned. Length alone never catches this, which is why the words are
    # counted as well.
    it "refuses a rewrite that is the right length" do
      cleans(
        { turn: 2, text: "Our autonomous system operates without supervision today, " \
                         "aside from periodic oversight on my part. The mechanism is " \
                         "a private messaging surface backed by a large language " \
                         "model, which staff may interrogate." },
      )

      expect(described_class.call(transcript).cleaned).to eq(0)
      expect(clean_of(2)).to be_nil
    end

    it "refuses a version longer than the turn it came from" do
      cleans({ turn: 2, text: "#{said} #{said}" })

      expect(described_class.call(transcript).cleaned).to eq(0)
      expect(clean_of(2)).to be_nil
    end

    # The figures are what an answer is worth and they are the first thing a
    # tightened sentence drops, so a missing one fails the whole turn rather
    # than being noticed later on a page of prose.
    it "refuses a cleaning that dropped a number" do
      transcript = transcript!(
        "How many?",
        "Um, so it owns about, uh, 27% of the task work now, up from, up from 21% " \
        "in, in June, and the error rate roughly halved over, over the same stretch " \
        "while the weekly volume, the volume tripled on us.",
      )
      cleans(
        { turn: 2, text: "So it owns about 27% of the task work now, up from June, " \
                         "and the error rate roughly halved over the same stretch " \
                         "while the weekly volume tripled on us." },
      )

      described_class.call(transcript)

      expect(transcript.reload.turns[1]["clean"]).to be_nil
    end

    # A reply that numbered from one rather than from the window would write
    # the first turn of the conversation over the first turn of every window
    # after the first.
    it "ignores an entry for a turn outside the window it was given" do
      cleans({ turn: 99, text: "Something about a turn that is not here." })

      expect(described_class.call(transcript).cleaned).to eq(0)
    end
  end

  # A turn that was nothing but noise has no readable version, and the page
  # leaves it out entirely rather than printing an empty bubble.
  describe "a turn that was all noise" do
    subject(:transcript) { transcript!("Anything else?", "Ooh. Um...") }

    it "keeps it as empty, so the readable version can drop it" do
      cleans({ turn: 1, text: "Anything else?" }, { turn: 2, text: "" })

      described_class.call(transcript)
      turn = transcript.reload.turns[1]

      expect(turn["clean"]).to eq("")
      expect(transcript.words_of(turn, clean: true)).to be_nil
      expect(transcript.words_of(turn)).to eq("Ooh. Um...")
    end

    # The floor is lifted for a short turn and not for a long one: an answer
    # reduced to silence is a dropped turn, not a cleaned one.
    it "refuses a long answer cleaned away to nothing" do
      transcript = transcript!("How does that run?", said)
      cleans({ turn: 2, text: "" })

      described_class.call(transcript)

      expect(transcript.reload.turns[1]["clean"]).to be_nil
    end
  end

  describe "the walk" do
    it "does not go over a transcript it has already cleaned unless asked twice" do
      transcript = transcript!("How does that run day to day?", said)
      cleans(
        { turn: 2, text: "So the agent now is almost entirely self-sufficient at " \
                         "this point, with guidance from me. But what happens is " \
                         "there is an internal chat with a Claude agent. We call " \
                         "it Coco, and the agents can ask questions from it." },
      )

      described_class.call(transcript)
      again = described_class.call(transcript)

      expect(again.ok).to be(false)
      expect(again.error).to eq(:done)
      expect(described_class.call(transcript, again: true).ok).to be(true)
    end

    # A window whose reply could not be read leaves its turns reading as they
    # were spoken, and a transcript where that happened to every window is not
    # stamped - otherwise the page would offer a cleaned read that is the
    # spoken one under a different name.
    it "writes nothing and leaves no stamp when nothing came back readable" do
      transcript = transcript!("How does that run day to day?", said)
      model_says("I could not do that.")

      result = described_class.call(transcript)

      expect(result.ok).to be(false)
      expect(result.error).to eq(:unusable)
      expect(transcript.reload.cleaned_at).to be_nil
    end

    it "carries the tail of the window before into the next call" do
      long = "#{said} " * 8
      transcript = transcript!(long, long, long)
      cleans

      described_class.call(transcript)

      expect(asked.size).to be > 1
      expect(asked.last).to include("WHAT WAS SAID JUST BEFORE THIS STRETCH")
    end

    it "says there was nothing to read for a transcript with no turns" do
      transcript = transcript!("Anything?")
      transcript.turns = []

      expect(described_class.call(transcript).error).to eq(:empty)
    end
  end
end
