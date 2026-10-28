require "rails_helper"

# A recording that came back with nobody named: a phone transcription is one
# unbroken half hour of text, and a recorder that only heard one voice puts the
# whole call on `Unknown`. Either way the page has nothing on it to read, and
# the question it has to answer afterwards is which of these answers were his.
RSpec.describe Transcripts::Speakers do
  let(:user) { User.me }
  let(:job) { user.job_applications.create!(company: "Bluestaq", role: "Principal Engineer") }

  # What each call was actually asked, in order. A window carries the stretch
  # before it, and the only way to say that it did is to read the prompt.
  def asked = (@asked ||= [])

  # A queue rather than `and_return(a, b)`: every call builds a fresh client, so
  # any_instance_of would hand back the first reply forever.
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

  def transcript!(turns)
    job.transcripts.create!(title: "Hiring manager", turns: turns)
  end

  def cued(*texts)
    texts.each_with_index.map { |text, index|
      {
        "raw"     => JobTranscript::UNKNOWN,
        "speaker" => JobTranscript::UNKNOWN,
        "at"      => index * 10.0,
        "to"      => (index * 10.0) + 8,
        "text"    => text,
      }
    }
  end

  describe "a file with timings and no names" do
    subject(:transcript) { transcript!(heard) }

    let(:heard) {
      cued(
        "Thanks for making the time. Tell me about something you built.",
        "The last big one was a mail consolidation, four inboxes into one.",
        "What went wrong with it?",
      )
    }

    it "puts every turn on a side and ticks the one that is him" do
      model_says({ sides: "tmt" }.to_json)

      expect(described_class.call(transcript).ok).to be(true)

      transcript.reload
      expect(transcript.turns.pluck("speaker")).to eq(%w[Them Me Them])
      expect(transcript.mine?("Me")).to be(true)
      expect(transcript.mine?("Them")).to be(false)
    end

    it "says how far along it is while it reads" do
      model_says({ sides: "tmt" }.to_json)
      seen = []

      described_class.call(transcript) { |done, total| seen << [done, total] }

      expect(seen).to eq([[1, 1]])
    end

    # A chunk that starts at turn 41 opens in the middle of an answer. Which
    # side that answer is on is settled by what came before it, and nothing
    # else - so the turns already placed go with the question.
    it "tells the next chunk what the last one settled" do
      many = transcript!(cued(*Array.new(45) { |index| "Turn number #{index}, with words in it." }))
      model_says({ sides: "t#{"m" * 39}" }.to_json, { sides: "mmmmm" }.to_json)

      described_class.call(many)

      expect(asked.length).to eq(2)
      expect(asked.first).not_to include("WHAT WAS SAID JUST BEFORE")
      expect(asked.last).to include("WHAT WAS SAID JUST BEFORE")
      expect(asked.last).to include("[m] Turn number 39")
      expect(asked.last).not_to include("[m] Turn number 20")
    end

    # The whole reason it is one letter per turn. A short answer lined up from
    # the top puts every turn after the miscount on the wrong side, which reads
    # as a working split - so a chunk that cannot be counted is thrown away.
    it "leaves the turns alone when the answer does not cover them" do
      model_says({ sides: "tm" }.to_json)

      result = described_class.call(transcript)

      expect(result.ok).to be(false)
      expect(transcript.reload.turns.pluck("speaker")).to all(eq(JobTranscript::UNKNOWN))
    end

    it "keeps the words and the timings exactly as they were" do
      model_says({ sides: "tmt" }.to_json)
      described_class.call(transcript)

      expect(transcript.reload.turns.first["text"]).to start_with("Thanks for making the time")
      expect(transcript.turns.first["at"]).to eq(0.0)
      expect(transcript.turns.last["to"]).to eq(28.0)
    end

    it "leaves a transcript alone once its speakers are settled" do
      transcript.update!(speakers: { "Unknown" => { "name" => "Dana", "me" => false } })

      expect_any_instance_of(Buddy::GPT::Client).not_to receive(:stream)
      expect(described_class.call(transcript).error).to eq(:settled)
    end
  end

  describe "a file that named people but never said which one is him" do
    subject(:transcript) {
      transcript!([
        {
          "raw"     => "Speaker 1",
          "speaker" => "Speaker 1",
          "text"    => "Hi, this is Dana at Bluestaq. Tell me about your last role.",
        },
        {
          "raw"     => "Speaker 2",
          "speaker" => "Speaker 2",
          "text"    => "Happy to. Four years at Slingshot, mostly on the mail platform.",
        },
      ])
    }

    def labels(*rows)
      { labels: rows.map { |label, side, name| { label: label, side: side, name: name } } }.to_json
    end

    it "ticks the one that is him and leaves the labels and turns alone" do
      model_says(labels(["Speaker 1", "t", "Dana"], ["Speaker 2", "m", ""]))

      expect(described_class.call(transcript).ok).to be(true)

      transcript.reload
      expect(transcript.mine?("Speaker 2")).to be(true)
      expect(transcript.mine?("Speaker 1")).to be(false)
      expect(transcript.name_for("Speaker 1")).to eq("Dana")
      expect(transcript.turns.pluck("speaker")).to eq(["Speaker 1", "Speaker 2"])
    end

    # A name that is not in the words is a guess wearing a reading's clothes.
    # The label stays what the recorder called it, which is honest and is what
    # the naming form is for.
    it "throws away a name the conversation never says" do
      model_says(labels(["Speaker 1", "t", "Dana"], ["Speaker 2", "m", "Rocco Nicholls"]))
      described_class.call(transcript)

      expect(transcript.reload.name_for("Speaker 2")).to eq("Speaker 2")
      expect(transcript.mine?("Speaker 2")).to be(true)
    end

    # Two labels both claiming his side is the one shape that makes the page
    # unreadable, so the first one marked keeps it.
    it "lets only one of them be him" do
      model_says(labels(["Speaker 1", "m", ""], ["Speaker 2", "m", ""]))
      described_class.call(transcript)

      transcript.reload
      expect(transcript.mine?("Speaker 1")).to be(true)
      expect(transcript.mine?("Speaker 2")).to be(false)
    end

    it "changes nothing when the reply names labels that are not in the file" do
      model_says(labels(["Speaker 7", "m", ""]))

      expect(described_class.call(transcript).ok).to be(false)
      expect(transcript.reload.speakers).to eq({})
    end
  end

  describe "one unbroken wall of text" do
    subject(:transcript) {
      transcript!([{
        "raw"     => JobTranscript::UNKNOWN,
        "speaker" => JobTranscript::UNKNOWN,
        "at"      => nil,
        "to"      => nil,
        "text"    => said,
      }])
    }

    let(:said) {
      "Thanks for making the time today, I know it is a busy week. " \
        "Happy to be here, I have been looking forward to it. " \
        "So tell me about something you built that you are proud of. " \
        "The one I come back to is a mail consolidation at Slingshot."
    }
    let(:every_handover) {
      cuts(
        ["t", "Thanks for making the time today"],
        ["m", "Happy to be here, I have been"],
        ["t", "So tell me about something you built"],
        ["m", "The one I come back to is a mail"],
      )
    }
    # The second quote is not in the file: the model tidied "Happy" into
    # "Delighted", which is the ordinary way a quote goes missing.
    let(:one_quote_wrong) {
      cuts(
        ["t", "Thanks for making the time today"],
        ["m", "Delighted to be here, looking forward to it"],
        ["t", "So tell me about something you built"],
      )
    }

    def cuts(*pairs)
      { turns: pairs.map { |who, starts| { who: who, starts: starts } } }.to_json
    end

    it "cuts it into turns at the handovers and sides each one" do
      model_says(every_handover)

      expect(described_class.call(transcript).ok).to be(true)

      transcript.reload
      expect(transcript.turns.pluck("speaker")).to eq(%w[Them Me Them Me])
      expect(transcript.turns[1]["text"]).to start_with("Happy to be here")
      expect(transcript.turns[2]["text"]).to start_with("So tell me about")
    end

    # The text is never taken from the reply - only the position of a quote in
    # the text he uploaded - so nothing the model tidies, corrects or invents
    # can reach the transcript.
    it "keeps every word of the upload and adds none" do
      model_says(every_handover)
      described_class.call(transcript)

      expect(transcript.reload.turns.pluck("text").join(" ")).to eq(said.strip)
    end

    it "drops a quote it cannot find rather than cutting in the wrong place" do
      model_says(one_quote_wrong)
      described_class.call(transcript)

      transcript.reload
      expect(transcript.turns.length).to eq(2)
      expect(transcript.turns.first["text"]).to include("Happy to be here")
    end

    # Half an hour of talking is several calls, and the second one opens
    # wherever the first one stopped - mid-answer, with nothing in front of it.
    # The stretch already settled goes with it so the voice carrying on can be
    # told from the one replying to it.
    context "when it takes more than one call" do
      subject(:long) {
        transcript!([{
          "raw"     => JobTranscript::UNKNOWN,
          "speaker" => JobTranscript::UNKNOWN,
          "at"      => nil,
          "to"      => nil,
          "text"    => wall,
        }])
      }

      let(:wall) {
        [
          "Thanks for making the time today, I know it is a busy week.",
          "Happy to be here. #{"I have been looking forward to this all week. " * 120}",
          "So tell me about something you built that you are proud of.",
          "The one I come back to is a mail consolidation at Slingshot. " \
          "#{"It took six attempts over about three months to land it. " * 110}",
        ].join(" ")
      }

      before do
        model_says(
          cuts(
            ["t", "Thanks for making the time today"],
            ["m", "Happy to be here. I have been"],
            ["t", "So tell me about something you built"],
          ),
          cuts(
            ["t", "So tell me about something you built"],
            ["m", "The one I come back to is a mail"],
          ),
        )
      end

      it "hands the next window the turns the last one settled" do
        described_class.call(long)

        expect(asked.length).to eq(2)
        expect(asked.first).not_to include("WHAT WAS SAID JUST BEFORE")
        expect(asked.last).to include("WHAT WAS SAID JUST BEFORE")
        expect(asked.last).to include("[t] Thanks for making the time today")
        expect(asked.last).to include("looking forward to this all week.")
      end

      # The end of the turn, not the start of it: the words next to the window
      # are the ones its opening is a reply to.
      it "carries the end of a long turn rather than all of it" do
        described_class.call(long)

        expect(asked.last).to include("[m] ...")
        expect(asked.last.length).to be < asked.first.length
      end

      # One answer running the whole length of a window. The handover at the
      # top of it is the only one there is, and re-reading from there would ask
      # the next call for the same stretch again.
      it "carries on past a window it got no ground on" do
        asked.clear
        monologue = transcript!([{
          "raw"     => JobTranscript::UNKNOWN,
          "speaker" => JobTranscript::UNKNOWN,
          "at"      => nil,
          "to"      => nil,
          "text"    => "So tell me about it. #{"It ran for about three months in the end. " * 300}",
        }])
        model_says(
          cuts(["t", "So tell me about it. It ran"]),
          cuts(["m", "It ran for about three months in the end."]),
        )

        described_class.call(monologue)

        expect(asked.length).to eq(2)
        expect(asked.last).not_to include("So tell me about it.")
      end

      it "counts the calls it is going to make" do
        seen = []

        described_class.call(long) { |done, total| seen << [done, total] }

        expect(seen.map(&:first)).to eq([1, 2])
        expect(seen.map(&:last).uniq).to eq([2])
      end
    end

    it "says so and changes nothing when the reply is not readable" do
      model_says("I am afraid I cannot help with that.")

      result = described_class.call(transcript)

      expect(result.ok).to be(false)
      expect(result.error).to eq(:unreadable)
      expect(transcript.reload.turns.length).to eq(1)
    end
  end
end
