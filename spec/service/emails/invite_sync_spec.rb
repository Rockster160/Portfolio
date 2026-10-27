require "rails_helper"

# An interview booked by mail existed only as a .ics file inside a message: the
# time was in the mail and never on the day. The same either way, deliberately
# - keying the behaviour to which inbox a recruiter happened to use means
# remembering which one they used in order to know where the meeting is.
RSpec.describe Emails::InviteSync do
  let(:user) { create(:user) }
  let(:agenda) { user.agendas.order(:id).first }

  def ics(
    uid: "booking-9f2@calendly.com",
    method: "REQUEST",
    sequence: 0,
    starts: "20261103T150000Z",
    ends: nil,
    summary: "Interview: Rocco Nicholls and Erin McDonald")
    ends ||= starts.sub(/T(\d{2})0000Z\z/) { "T#{Regexp.last_match(1)}4500Z" }
    [
      "BEGIN:VCALENDAR",
      "METHOD:#{method}",
      "BEGIN:VEVENT",
      "UID:#{uid}",
      "SEQUENCE:#{sequence}",
      "SUMMARY:#{summary}",
      "DTSTART:#{starts}",
      "DTEND:#{ends}",
      "LOCATION:Google Meet",
      "DESCRIPTION:Bring questions.",
      "ORGANIZER;CN=Erin McDonald:mailto:erin@acme.test",
      "ATTENDEE;CN=Erin McDonald;PARTSTAT=ACCEPTED:mailto:erin@acme.test",
      "ATTENDEE;CN=Rocco Nicholls;PARTSTAT=NEEDS-ACTION:mailto:rocco@example.com",
      "END:VEVENT",
      "END:VCALENDAR",
    ].join("\r\n")
  end

  # The shape the pickup used to miss: the calendar is a FILE, and its type says
  # nothing about calendars.
  def rfc822(
    calendar: ics,
    content_type: "application/ics; name=\"invite.ics\"",
    to: "Rocco Nicholls <rocco@example.com>")
    [
      "From: Erin McDonald <erin@acme.test>",
      "To: #{to}",
      "Subject: Invitation: Interview",
      "Message-ID: <#{SecureRandom.hex(6)}@acme.test>",
      "Date: Mon, 27 Oct 2026 09:00:00 -0600",
      "MIME-Version: 1.0",
      'Content-Type: multipart/mixed; boundary="xx"',
      "",
      "--xx",
      "Content-Type: text/plain; charset=UTF-8",
      "",
      "Looking forward to it.",
      "",
      "--xx",
      "Content-Type: #{content_type}",
      'Content-Disposition: attachment; filename="invite.ics"',
      "Content-Transfer-Encoding: base64",
      "",
      Base64.encode64(calendar),
      "--xx--",
      "",
    ].join("\n")
  end

  def deliver(**args)
    email = Emails::StoreRaw.call(user: user, raw: rfc822(**args))
    described_class.call(email)
  end

  it "puts the booking on the calendar" do
    item = deliver

    expect(item.agenda).to eq(agenda)
    expect(item.kind).to eq("event")
    expect(item.name).to eq("Interview: Rocco Nicholls and Erin McDonald")
    expect(item.start_at).to eq(Time.utc(2026, 11, 3, 15, 0))
    expect(item.end_at).to eq(Time.utc(2026, 11, 3, 15, 45))
    expect(item.location).to eq("Google Meet")
  end

  it "reads a calendar sent as a file with no calendar in its type" do
    expect(deliver(content_type: "application/octet-stream; name=\"invite.ics\"")).to be_present
  end

  it "keeps the guest list and marks which one is him" do
    item = deliver

    expect(item.organizer).to include("email" => "erin@acme.test")
    expect(item.attendees.pluck("email")).to eq(["erin@acme.test", "rocco@example.com"])
    expect(item.attendees.find { |a| a["self"] }["email"]).to eq("rocco@example.com")
    expect(item.self_response).to eq("needsAction")
    expect(item.needs_response?).to be(true)
  end

  it "is answerable, and says which address answers" do
    item = deliver

    expect(item.mail_invite?).to be(true)
    expect(item.invite_details).to include("uid" => "booking-9f2@calendly.com", "replying_as" => "rocco@example.com")
  end

  # Calendly mails the invitee a copy that lists only the organizer.
  it "still has an answer to give when the invite forgot to list him" do
    item = deliver(calendar: ics.sub("ATTENDEE;CN=Rocco Nicholls;PARTSTAT=NEEDS-ACTION:mailto:rocco@example.com\r\n", ""))

    expect(item.attendees.find { |a| a["self"] }["email"]).to eq("rocco@example.com")
  end

  it "moves the row it already wrote rather than booking a second meeting" do
    first = deliver
    second = deliver(calendar: ics(sequence: 1, starts: "20261104T160000Z"))

    expect(second.id).to eq(first.id)
    expect(second.start_at).to eq(Time.utc(2026, 11, 4, 16, 0))
    expect(AgendaItem.where(agenda: agenda).count).to eq(1)
  end

  # Two moves can arrive in either order, because one of them sat in a queue.
  it "ignores a move older than the one already on the row" do
    deliver(calendar: ics(sequence: 2, starts: "20261105T170000Z"))
    again = deliver(calendar: ics(sequence: 1, starts: "20261104T160000Z"))

    expect(again.start_at).to eq(Time.utc(2026, 11, 5, 17, 0))
  end

  it "takes the meeting off the day when it's called off" do
    booked = deliver
    cancelled = deliver(calendar: ics(method: "CANCEL", sequence: 1))

    expect(cancelled.id).to eq(booked.id)
    expect(cancelled.status).to eq("cancelled")
  end

  # Which inbox the recruiter happened to use is not something he should have
  # to remember in order to know where the meeting is.
  it "books it the same when a calendar Google already syncs was the one invited" do
    account = GoogleAccount.create!(user: user, email: "rocco@example.com")
    create(:agenda, user: user, source: :google, google_account: account, external_id: "cal")

    expect(deliver).to be_present
  end

  # The organizer matches a reply by the attendee it invited, and mail can only
  # leave from a domain we control. On an invite to an address that is neither,
  # those are two different addresses.
  it "keeps who answers apart from who sends" do
    item = deliver(to: "Rocco Nicholls <rocco11nicholls@gmail.com>")

    expect(item.invite_details["replying_as"]).to eq("rocco11nicholls@gmail.com")
    expect(item.invite_details["sending_from"]).to eq("contact@ardesian.com")
  end

  it "answers as the address that was invited where it is one of ours" do
    item = deliver(to: "Rocco Nicholls <rocco@ardesian.com>")

    expect(item.invite_details.values_at("replying_as", "sending_from")).to all(eq("rocco@ardesian.com"))
  end

  # A webinar announcement and a newsletter's "add this to your calendar" both
  # carry a perfectly good event, and neither is an appointment.
  it "does not book an event nobody asked him to attend" do
    calendar = ics(method: "PUBLISH").sub("ATTENDEE;CN=Rocco Nicholls;PARTSTAT=NEEDS-ACTION:mailto:rocco@example.com\r\n", "")

    expect(deliver(calendar: calendar)).to be_nil
  end

  it "books one that names him as a guest whatever the invite calls itself" do
    expect(deliver(calendar: ics(method: "PUBLISH"))).to be_present
  end

  # `Emails::InviteReply` files the copy it sent, filing goes through StoreRaw,
  # and StoreRaw comes back through here. Without the guard, clicking Yes cut
  # the guest list down to the one attendee a reply names.
  it "does not read his own answer back in as a new invitation" do
    booked = deliver
    guests = booked.attendees

    Emails::StoreRaw.call(
      user:      user,
      raw:       rfc822(calendar: ics(method: "REPLY"), to: "Erin McDonald <erin@acme.test>"),
      direction: :outbound,
    )

    expect(booked.reload.attendees).to eq(guests)
    expect(AgendaItem.count).to eq(1)
  end

  it "ignores an answer that arrives as inbound mail too" do
    expect(deliver(calendar: ics(method: "REPLY"))).to be_nil
  end

  it "files no tombstone for a meeting that was never on the day" do
    expect(deliver(calendar: ics(method: "CANCEL"))).to be_nil
    expect(AgendaItem.count).to eq(0)
  end

  it "does nothing with mail that carries no invite" do
    email = Emails::StoreRaw.call(user: user, raw: rfc822(calendar: "BEGIN:VCALENDAR\r\nEND:VCALENDAR"))

    expect(described_class.call(email)).to be_nil
  end
end
