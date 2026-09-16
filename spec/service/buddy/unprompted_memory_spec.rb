require "rails_helper"

# Prod 6243, 15 Sep: a morning briefing that closed by announcing it was
# holding one of the heavy things the person is carrying, against a bolded
# instruction not to, on a turn where the seed had said nothing about it.
RSpec.describe Buddy::UnpromptedMemory do
  # A carried memory is only ever read for its `content` here, so the spec does
  # not need a record - and must not leak a constant to get one.
  let(:held) { Struct.new(:content) }

  let(:facts) {
    { weather: ["High 74°F, low 53°F"], today: ["9:00am · Dentist"], jobs: [] }
  }
  let(:carried) { [held.new("Be mindful about how the audit at work might affect me")] }

  def trim(body) = described_class.trim(body, carried, facts)

  it "drops the sentence that names it" do
    body = "Morning! And I'm holding that audit note for you too, so you don't have to keep it in your head."

    expect(trim(body)).to eq("Morning!")
  end

  it "leaves the rest of the briefing exactly as written" do
    body = "High of 74 today.\n\nDentist at 9.\n\nI know the audit is on your mind."

    expect(trim(body)).to eq("High of 74 today.\n\nDentist at 9.")
  end

  # The half that must not be lost. Being SHAPED by it is the whole point of
  # carrying it; only SAYING it is off limits.
  it "says nothing about a gentler tone that names nothing" do
    body = "Morning - take it easy today if you can, and leave yourself some room."

    expect(trim(body)).to eq(body)
  end

  # If the seed carried it, the seed decided it was today's subject, and the
  # briefing is allowed to say it.
  it "allows a word the facts themselves carried" do
    body = "The audit is at 9:00am, so the morning is spoken for."
    facts_with = facts.merge(today: ["9:00am · Audit at work"])

    expect(described_class.trim(body, carried, facts_with)).to eq(body)
  end

  it "keeps a body that was nothing else" do
    body = "I'm still holding that audit note for you."

    expect(trim(body)).to eq(body)
  end

  it "does nothing when they are carrying nothing" do
    body = "Morning! High of 74 and a clear afternoon."

    expect(described_class.trim(body, [], facts)).to eq(body)
  end

  # The words in a carried memory are the most private thing this system holds.
  # They are read to decide a drop and never written anywhere.
  it "keeps the memory's words out of the log" do
    allow(Rails.logger).to receive(:info)

    trim("Morning! I'm holding that audit note for you.")

    expect(Rails.logger).to have_received(:info) { |line| expect(line).not_to include("audit") }
  end
end
