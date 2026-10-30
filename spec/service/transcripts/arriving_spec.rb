require "rails_helper"

# A call the laptop recorded by itself, arriving the moment it ended.
#
# Two streams captured separately, so who said what is not a guess: everything
# off the microphone is his and everything off the call is theirs. What the
# recorder sends is a few seconds of words at a time; the turns are built here.
RSpec.describe Transcripts::Arriving do
  let(:user) { User.me }

  before { allow(TranscriptSpeakersWorker).to receive(:perform_async) }

  def payload(**given)
    {
      started_at: "2026-10-29T14:02:00-06:00",
      source:     { app: "Chrome", bundle: "com.google.Chrome", host: "meet.google.com" },
      segments:   [
        { who: "them", at: 0.0, to: 3.2, text: "Thanks for making the time." },
        { who: "me",   at: 3.6, to: 6.0, text: "Thanks for having me." },
      ],
    }.merge(given)
  end

  describe "the conversation it builds" do
    it "marks his side as his and theirs as theirs" do
      transcript = described_class.call(user, payload)

      expect(transcript.turns.map { |turn| turn["speaker"] }).to eq(["Them", "Me"])
      expect(transcript.mine?("Me")).to be(true)
      expect(transcript.mine?("Them")).to be(false)
      expect(transcript.owner).to eq(user)
    end

    # The whole reason the two streams share one clock: the conversation IS the
    # interleaving, and a sort per side would put his answers after all of
    # their questions.
    it "interleaves the two sides on one clock" do
      segments = [
        { who: "me",   at: 10.0, to: 12.0, text: "Second." },
        { who: "them", at: 0.0,  to: 2.0,  text: "First." },
        { who: "them", at: 20.0, to: 22.0, text: "Third." },
      ]

      transcript = described_class.call(user, payload(segments: segments))

      expect(transcript.turns.map { |turn| turn["text"] }).to eq(["First.", "Second.", "Third."])
    end

    # What comes off a speech model is seconds of words at a time, which is not
    # how a conversation reads. The rule is the same gap the file parser uses.
    it "stitches a run of segments from one side into a turn" do
      segments = [
        { who: "me", at: 0.0, to: 2.0, text: "The last big one" },
        { who: "me", at: 2.4, to: 4.0, text: "was a mail consolidation." },
        { who: "me", at: 30.0, to: 32.0, text: "A long pause came before this." },
      ]

      transcript = described_class.call(user, payload(segments: segments))

      expect(transcript.turns.length).to eq(2)
      expect(transcript.turns.first["text"]).to eq("The last big one was a mail consolidation.")
      expect(transcript.turns.first["to"]).to eq(4.0)
      expect(transcript.turns.last["at"]).to eq(30.0)
    end

    it "keeps where it came from, for naming it and for refusing the source" do
      transcript = described_class.call(user, payload)

      expect(transcript.source["host"]).to eq("meet.google.com")
      expect(transcript.source_key).to eq("meet.google.com")
      expect(transcript.title).to eq("Chrome")
    end

    it "reads the start in his own zone" do
      transcript = described_class.call(user, payload)

      expect(transcript.occurred_at).to eq(Time.zone.parse("2026-10-29T14:02:00-06:00"))
    end

    # His microphone hot with nothing coming back is usually dictation or a
    # room - but it is also a phone on speaker, so it is marked and kept.
    it "marks a recording only one side of which made a sound" do
      segments = [{ who: "me", at: 0.0, to: 4.0, text: "Reading something out loud." }]

      expect(described_class.call(user, payload(segments: segments))).to be_one_sided
    end

    it "drops a segment on a side it does not recognise" do
      segments = payload[:segments] + [{ who: "nobody", at: 9.0, to: 10.0, text: "Who?" }]

      transcript = described_class.call(user, payload(segments: segments))

      expect(transcript.turns.length).to eq(2)
    end

    it "is nothing at all when there were no words in it" do
      expect(described_class.call(user, payload(segments: []))).to be_nil
    end
  end

  describe "what happens to it next" do
    # The pass that works out who was talking has nothing to do here - the
    # streams already settled it - so it refuses this one and hands straight
    # on to the words.
    it "arrives with the speakers already settled" do
      transcript = described_class.call(user, payload)

      expect(Transcripts::Speakers.call(transcript).error).to eq(:settled)
      expect(TranscriptSpeakersWorker).to have_received(:perform_async).with(transcript.id)
    end

    it "files itself on the interview the clock says it was" do
      job = user.job_applications.create!(company: "Podium")
      job.notes.create!(tag: :interview, occurred_at: Time.zone.parse("2026-10-29T14:00:00-06:00"))

      transcript = described_class.call(user, payload)

      expect(transcript.job_application).to eq(job)
    end

    it "arrives unfiled when the clock cannot say which interview it was" do
      expect(described_class.call(user, payload)).not_to be_filed
    end
  end
end
