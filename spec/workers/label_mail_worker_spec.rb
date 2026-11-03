require "rails_helper"

# Mail.app cannot remove a Gmail inbox label, so the board labels the message
# instead and the archiving stays a human gesture. See LabelMailWorker.
RSpec.describe LabelMailWorker do
  let(:user) { create(:user) }
  let(:email) {
    user.emails.create!(
      direction: :inbound,
      mail_id:   "abc123@mail.example",
      subject:   "Thanks for applying",
      blurb:     "Thanks for applying.",
      timestamp: 1.hour.ago,
    )
  }

  it "asks the Mac to label it by its Message-ID" do
    expect(ByteLocal).to receive(:label_mail)
      .with(message_id: "abc123@mail.example")
      .and_return({ ok: true, state: "labelled", note: "tagged" })

    described_class.new.perform(email.id)
  end

  # Emails::StoreRaw invents one for mail that arrived without a Message-ID.
  # Nothing on the Mac can match an id that was never on the wire, so the round
  # trip is pure cost - and it would wake a sleeping machine to fail.
  it "does not go looking for mail that never had an id" do
    invented = user.emails.create!(
      direction: :inbound,
      mail_id:   "no-message-id-1758000000",
      subject:   "No id on the wire",
      blurb:     "None.",
      timestamp: 1.hour.ago,
    )
    expect(ByteLocal).not_to receive(:label_mail)

    described_class.new.perform(invented.id)
  end

  it "does nothing for an email that is gone" do
    expect(ByteLocal).not_to receive(:label_mail)

    expect { described_class.new.perform(0) }.not_to raise_error
  end

  # A sleeping Mac is the ordinary case, not a fault. The Ardesian side is
  # already saved by the time this runs and nobody is holding a turn on it.
  it "swallows a Mac that isn't there" do
    allow(ByteLocal).to receive(:label_mail).and_return({ ok: false, error: "asleep" })

    expect { described_class.new.perform(email.id) }.not_to raise_error
  end

  # Anything short of done has to be findable: a Gmail no-op is not success.
  it "warns when the label did not go on, and only then" do
    allow(PrettyLogger).to receive(:warn)
    allow(ByteLocal).to receive(:label_mail).and_return({ ok: true, state: "labelled", note: "tagged" })
    described_class.new.perform(email.id)
    expect(PrettyLogger).not_to have_received(:warn)

    allow(ByteLocal).to receive(:label_mail).and_return({ ok: true, state: "nolabel", note: "no such mailbox" })
    described_class.new.perform(email.id)
    expect(PrettyLogger).to have_received(:warn).once
  end
end
