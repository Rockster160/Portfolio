require "rails_helper"

# What the Mac watcher finds used to reach Rails as flattened plaintext in a
# webhook field: enough to say what happened, not enough to keep. A beat logged
# off Gmail was strictly poorer than the same beat logged off ardesian, where
# `add_job_note` picks up the date, the sender and a link back purely by being
# handed an `email_id`.
RSpec.describe Emails::StoreRaw do
  let(:user) { create(:user) }

  def rfc822(
    subject: "Thank you for applying to ApartmentIQ!",
    message_id: "<abc123@greenhouse-mail.io>",
    date: "Fri, 11 Sep 2026 09:28:11 -0600",
    body: "Rocco,\n\nThanks for applying to ApartmentIQ!\n")
    [
      "From: ApartmentIQ <no-reply@us.greenhouse-mail.io>",
      "To: Rocco Nicholls <rocco@example.com>",
      "Subject: #{subject}",
      ("Message-ID: #{message_id}" if message_id),
      ("Date: #{date}" if date),
      "Content-Type: text/plain; charset=UTF-8",
      "",
      body,
    ].compact.join("\n")
  end

  it "keeps one row with the mail's own headers on it" do
    email = described_class.call(user: user, raw: rfc822)

    expect(email.subject).to eq("Thank you for applying to ApartmentIQ!")
    expect(email.mail_id).to eq("abc123@greenhouse-mail.io")
    expect(email.timestamp).to eq(Time.parse("Fri, 11 Sep 2026 09:28:11 -0600"))
    expect(email.blurb).to include("Thanks for applying to ApartmentIQ!")
  end

  # The bytes themselves, not the plaintext — the whole point is having the mail
  # to go back to.
  it "puts the message itself on S3" do
    email = described_class.call(user: user, raw: rfc822)

    expect(email.mail_blob).to be_attached
    expect(email.mail_blob.download).to include("Message-ID: <abc123@greenhouse-mail.io>")
  end

  # `inbound_mailboxes` is US and `outbound_mailboxes` is THEM. The names
  # describe the direction the mail travelled, so on something they sent, the
  # two swap over — and the `with_outbound_address` scopes read the wrong half
  # of every sent mail if they don't.
  it "files an arriving mail with the sender as the other party" do
    email = described_class.call(user: user, raw: rfc822)

    expect(email).to be_inbound
    expect(email.outbound_mailboxes.first[:address]).to eq("no-reply@us.greenhouse-mail.io")
    expect(email.inbound_mailboxes.first[:address]).to eq("rocco@example.com")
  end

  it "swaps them round on one they sent" do
    email = described_class.call(user: user, raw: rfc822, direction: :outbound)

    expect(email).to be_outbound
    expect(email.inbound_mailboxes.first[:address]).to eq("no-reply@us.greenhouse-mail.io")
    expect(email.outbound_mailboxes.first[:address]).to eq("rocco@example.com")
  end

  # They read it in Gmail days before this row existed. Landing unread puts a
  # number on the app's mail badge for something already dealt with elsewhere.
  it "arrives already read" do
    expect(described_class.call(user: user, raw: rfc822).read_at).to be_present
  end

  it "carries the watcher's verdict so nothing triages it a second time" do
    email = described_class.call(
      user: user, raw: rfc822, triage: { job: true, company: "ApartmentIQ", kind: "application confirmation" },
    )

    expect(Email.job_mail).to include(email)
    expect(email.job_triage[:company]).to eq("ApartmentIQ")
  end

  # A Gmail label makes a second row in Mail.app's index, so the same mail can
  # arrive here twice.
  it "is the same row the second time the same mail arrives" do
    first  = described_class.call(user: user, raw: rfc822)
    second = described_class.call(user: user, raw: rfc822)

    expect(second.id).to eq(first.id)
    expect(user.emails.count).to eq(1)
  end

  # Mail with no Message-ID still must not make a row per attempt.
  it "gives mail with no message id a stable stand-in" do
    first  = described_class.call(user: user, raw: rfc822(message_id: nil))
    second = described_class.call(user: user, raw: rfc822(message_id: nil))

    expect(second.id).to eq(first.id)
  end

  describe "what it declines" do
    # Nil means "carry on without one" everywhere it's called. A beat announced
    # without its paperwork is worth far more than a beat not announced.
    it "is nil for a mail too big to ride through a webhook" do
      stub_const("#{described_class}::MAX_BYTES", 100)

      expect(described_class.call(user: user, raw: rfc822)).to be_nil
    end

    it "is nil when there was no raw copy" do
      expect(described_class.call(user: user, raw: nil)).to be_nil
    end

    it "is nil rather than raising on something that isn't mail at all" do
      allow(Rails.logger).to receive(:warn)
      allow(Emails::ParseMail).to receive(:call).and_raise("not mail")

      expect(described_class.call(user: user, raw: rfc822)).to be_nil
    end
  end

  # The shape the watcher actually hands over: Gmail's own Delivered-To/Received
  # preamble, and a multipart/alternative body. The blurb has to come off the
  # text part rather than off the raw source, or it reads as MIME boundaries.
  it "reads a real multipart message the way the watcher sends one" do
    source = [
      "Delivered-To: rocco@example.com",
      "Received: by 2002:a05 with SMTP id y19; Fri, 11 Sep 2026 08:28:12 -0700 (PDT)",
      "Date: Fri, 11 Sep 2026 15:28:11 +0000",
      "Subject: Thank you for applying to ApartmentIQ!",
      "From: no-reply@us.greenhouse-mail.io",
      "To: rocco@example.com",
      "Message-ID: <20260911152811@us.greenhouse-mail.io>",
      "MIME-Version: 1.0",
      "Content-Type: multipart/alternative; boundary=\"bound42\"",
      "",
      "--bound42",
      "Content-Type: text/plain; charset=UTF-8",
      "",
      "Rocco,\n\nThanks for applying to ApartmentIQ!",
      "--bound42",
      "Content-Type: text/html; charset=UTF-8",
      "",
      "<p>Rocco,</p><p>Thanks for applying to ApartmentIQ!</p>",
      "--bound42--",
      "",
    ].join("\n")

    email = described_class.call(user: user, raw: source)

    expect(email.subject).to eq("Thank you for applying to ApartmentIQ!")
    expect(email.blurb).to include("Thanks for applying to ApartmentIQ!")
    expect(email.blurb).not_to include("bound42")
    expect(email).not_to be_has_attachments
    expect(email.outbound_mailboxes.first[:address]).to eq("no-reply@us.greenhouse-mail.io")
  end

  # Mail.app dates it, but a message without a Date header would otherwise fail
  # a NOT NULL column.
  it "falls back to when it was announced" do
    at = 3.hours.ago.change(usec: 0)

    email = described_class.call(user: user, raw: rfc822(date: nil), occurred_at: at)

    expect(email.timestamp).to be_within(1.second).of(at)
  end
end
