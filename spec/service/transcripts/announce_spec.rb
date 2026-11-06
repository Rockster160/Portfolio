require "rails_helper"

# The message that says a recording can be read now.
#
# Two of the four passes run beside each other, so neither of them knows it is
# the last one. Both ask, and the examples here are mostly about the arithmetic
# of that: once every pass has been over it, exactly one message, and nothing
# said while a pass is still to come.
RSpec.describe Transcripts::Announce do
  let(:user) { User.me }
  let(:job) { user.job_applications.create!(company: "Podium", role: "Staff Engineer") }
  let(:transcript) {
    job.transcripts.create!(
      title:    "Hiring manager",
      turns:    [
        {
          "raw"     => "Unknown",
          "speaker" => "Me",
          "text"    => "Thanks for the time.",
          "heard"   => "Thanks for the thyme.",
        },
        {
          "raw"     => "Unknown",
          "speaker" => "Me",
          "text"    => "Um, so, the agent runs itself.",
          "clean"   => "So the agent runs itself.",
        },
      ],
      speakers: { "Me" => { "name" => "Rocco", "me" => true } },
    )
  }

  before { user.byte_conversations.create!(name: "Byte", mode: :buddy) }

  def told
    said = ByteConversation.for_self_initiated(user).byte_messages
    said.where("metadata->>'source' = ?", "transcript_ready")
  end

  def every_pass_over_it
    transcript.update!(
      tidied_at:    Time.current,
      debriefed_at: Time.current,
      cleaned_at:   Time.current,
      debrief:      {
        "read"      => "It went well.",
        "strongest" => [{ "turn" => 1, "why" => "A number in it." }],
        "cost"      => [],
        "missed"    => [{ "what" => "Never said he wanted it." }],
        "next"      => ["Ask what happens next."],
      },
    )
  end

  it "says nothing until every pass has been over it" do
    transcript.update!(tidied_at: Time.current, cleaned_at: Time.current)

    expect(described_class.call(transcript)).to be(false)
    expect(told).to be_empty
    expect(transcript.reload.announced_at).to be_nil
  end

  it "sends one message carrying the link and what the passes found" do
    every_pass_over_it

    expect(described_class.call(transcript)).to be(true)
    said = told.sole

    expect(said.body).to include(transcript.reading_url(read: :clean))
    expect(said.body).to include("Podium is read and cleaned up")
    expect(said.body).to include("2 turns", "1 put right", "1 cleaned", "3 notes")
    expect(transcript.reload.announced_at).to be_present
  end

  # The whole reason the claim is an UPDATE guarded on the stamp: both passes
  # can finish on two threads inside the same instant, and both would find a
  # finished recording.
  it "speaks once when both passes ask" do
    every_pass_over_it

    expect(described_class.call(transcript)).to be(true)
    expect(described_class.call(transcript.reload)).to be(false)
    expect(told.count).to eq(1)
  end

  # Holding the claim after a failure would mark him as told about a message
  # that never arrived, and nothing would try again.
  it "puts the claim back when there was nowhere to say it" do
    user.byte_conversations.destroy_all
    every_pass_over_it

    expect(described_class.call(transcript)).to be(false)
    expect(transcript.reload.announced_at).to be_nil
  end

  # An unfiled recording has no page of its own, and the index is where it
  # would be filed from.
  it "links an unfiled recording to the interview index" do
    loose = user.job_transcripts.create!(
      turns: [{ "raw" => "Unknown", "speaker" => "Me", "text" => "Testing." }],
    )

    expect(loose.reading_url).to end_with("/interviews")
  end
end
