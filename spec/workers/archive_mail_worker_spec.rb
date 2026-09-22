require "rails_helper"

# The half of the archive that reaches mail living somewhere else. An `Email`
# row is a COPY: domain mail has Ardesian for a client, but Gmail mail is
# mirrored in by the watcher and stays bold in the real inbox until Mail.app on
# the desk Mac is told.
RSpec.describe ArchiveMailWorker do
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

  it "asks the Mac to archive it by its Message-ID" do
    expect(ByteLocal).to receive(:archive_mail)
      .with(message_id: "abc123@mail.example")
      .and_return({ ok: true, state: "archived", note: "done" })

    described_class.new.perform(email.id)
  end

  # Emails::StoreRaw invents one for mail that arrived without a Message-ID.
  # Nothing on the Mac can match an id that was never on the wire, so the round
  # trip is pure cost — and it would wake a sleeping machine to fail.
  it "does not go looking for mail that never had an id" do
    invented = user.emails.create!(
      direction: :inbound,
      mail_id:   "no-message-id-1758000000",
      subject:   "No id on the wire",
      blurb:     "None.",
      timestamp: 1.hour.ago,
    )
    expect(ByteLocal).not_to receive(:archive_mail)

    described_class.new.perform(invented.id)
  end

  it "does nothing for an email that is gone" do
    expect(ByteLocal).not_to receive(:archive_mail)

    expect { described_class.new.perform(0) }.not_to raise_error
  end

  # A sleeping Mac is the ordinary case, not a fault. The Ardesian side of the
  # archive is already saved by the time this runs, and nobody is holding a turn
  # on it, so this logs and stops rather than raising into a retry loop.
  it "swallows a Mac that isn't there" do
    allow(ByteLocal).to receive(:archive_mail).and_return({ ok: false, error: "asleep" })

    expect { described_class.new.perform(email.id) }.not_to raise_error
  end

  it "never retries" do
    expect(described_class.sidekiq_options["retry"]).to be(false)
  end
end
