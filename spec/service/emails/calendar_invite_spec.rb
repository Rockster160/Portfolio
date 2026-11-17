require "rails_helper"

RSpec.describe Emails::CalendarInvite do
  # The shape Outlook sends: a Windows zone name, and VTIMEZONE blocks above the
  # event with DTSTARTs of their own for when each rule began.
  let(:outlook) {
    <<~ICS.gsub("\n", "\r\n")
      BEGIN:VCALENDAR
      METHOD:REQUEST
      PRODID:Microsoft Exchange Server 2010
      BEGIN:VTIMEZONE
      TZID:Eastern Standard Time
      BEGIN:STANDARD
      DTSTART:16010101T020000
      TZOFFSETTO:-0500
      END:STANDARD
      END:VTIMEZONE
      BEGIN:VEVENT
      SUMMARY;LANGUAGE=en-US:Rocco Nicholls and Erin McDonald
      DTSTART;TZID=Eastern Standard Time:20261027T133000
      DTEND;TZID=Eastern Standard Time:20261027T140000
      LOCATION;LANGUAGE=en-US:+1 385-259-9640
      DESCRIPTION:a long line that
        carries on
      END:VEVENT
      END:VCALENDAR
    ICS
  }

  it "reads the event's own start, not the time zone rule's" do
    invite = described_class.parse(outlook)

    expect(invite[:starts_at]).to eq(Time.utc(2026, 10, 27, 17, 30))
    expect(invite[:ends_at]).to eq(Time.utc(2026, 10, 27, 18, 0))
  end

  it "reads what and where" do
    invite = described_class.parse(outlook)

    expect(invite).to include(summary: "Rocco Nicholls and Erin McDonald", location: "+1 385-259-9640", cancelled: false)
  end

  it "reads a UTC stamp" do
    invite = described_class.parse(outlook.sub("DTSTART;TZID=Eastern Standard Time:20261027T133000", "DTSTART:20261027T173000Z"))

    expect(invite[:starts_at]).to eq(Time.utc(2026, 10, 27, 17, 30))
  end

  it "reads an IANA zone" do
    invite = described_class.parse(outlook.gsub("Eastern Standard Time:", "America/Denver:"))

    expect(invite[:starts_at]).to eq(Time.utc(2026, 10, 27, 19, 30))
  end

  # Guessing a zone would book the interview at the wrong hour.
  it "places nothing it can't place" do
    expect(described_class.parse(outlook.gsub("DTSTART;TZID=Eastern Standard Time:", "DTSTART:"))).to be_nil
    expect(described_class.parse(outlook.gsub("DTSTART;TZID=Eastern Standard Time:20261027T133000", "DTSTART;VALUE=DATE:20261027"))).to be_nil
  end

  it "says when the invite is calling the booking off" do
    expect(described_class.parse(outlook.sub("METHOD:REQUEST", "METHOD:CANCEL"))[:cancelled]).to be(true)
  end

  it "finds the calendar part in a mail" do
    ics = outlook
    mail = Mail.new {
      text_part { body "Need to make changes to this event?" }
      add_part(Mail::Part.new { content_type "text/calendar; method=REQUEST"; body ics })
    }

    invite = Emails::ParseMail.call(mail).calendar_invite

    expect(invite[:starts_at]).to eq(Time.utc(2026, 10, 27, 17, 30))
  end

  it "is nil for a mail without one" do
    expect(Emails::ParseMail.call(Mail.new { body "Hello" }).calendar_invite).to be_nil
  end

  # A forwarded invite arrives as a FILE, and its type says nothing about
  # calendars. For months those were mail with no time in it at all.
  it "finds the calendar sent as a file" do
    ics = outlook
    mail = Mail.new {
      text_part { body "Looking forward to it." }
      add_file(filename: "invite.ics", content: ics)
      parts.last.content_type = "application/octet-stream; name=invite.ics"
    }

    expect(Emails::ParseMail.call(mail).calendar_invite[:starts_at]).to eq(Time.utc(2026, 10, 27, 17, 30))
  end

  # The handle a reschedule lands on, and the two things a reply has to quote
  # back for the organizer's calendar to accept it.
  it "reads what identifies the event" do
    invite = described_class.parse(outlook.sub("BEGIN:VEVENT", "BEGIN:VEVENT\r\nUID:abc-123@acme.test\r\nSEQUENCE:2"))

    expect(invite).to include(uid: "abc-123@acme.test", sequence: 2, method: "REQUEST")
  end

  it "reads the guest list, as the agenda already stores one" do
    invite = described_class.parse(
      outlook.sub(
        "BEGIN:VEVENT",
        "BEGIN:VEVENT\r\nORGANIZER;CN=Erin McDonald:mailto:Erin@Acme.test\r\n" \
        "ATTENDEE;CN=Rocco;PARTSTAT=ACCEPTED:mailto:rocco@example.com\r\n" \
        "ATTENDEE;ROLE=OPT-PARTICIPANT:mailto:panel@acme.test",
      ),
    )

    expect(invite[:organizer]).to eq(
      "email"           => "erin@acme.test",
      "display_name"    => "Erin McDonald",
      "response_status" => "needsAction",
      "optional"        => false,
    )
    expect(invite[:attendees].pluck("email")).to eq(["rocco@example.com", "panel@acme.test"])
    expect(invite[:attendees].first["response_status"]).to eq("accepted")
    expect(invite[:attendees].last["optional"]).to be(true)
  end

  # Anything else - DELEGATED, IN-PROCESS - means "not yet" to anybody looking
  # at who is coming.
  it "reads an answer it does not know as no answer" do
    invite = described_class.parse(
      outlook.sub("BEGIN:VEVENT", "BEGIN:VEVENT\r\nATTENDEE;PARTSTAT=DELEGATED:mailto:rocco@example.com"),
    )

    expect(invite[:attendees].first["response_status"]).to eq("needsAction")
  end

  # WHAT EXCHANGE ACTUALLY SENDS for a Teams meeting: LOCATION present and
  # empty, the join link only in the organizer's words. The slot was being
  # booked with nowhere on it, so there was nothing to tap on the day.
  let(:teams) {
    outlook.sub(
      "LOCATION;LANGUAGE=en-US:+1 385-259-9640",
      "LOCATION;LANGUAGE=en-US:\r\nDESCRIPTION;LANGUAGE=en-US:Join the Microsoft Teams " \
      "meeting: https://gov.teams.microsoft.us/l/meetup-join/19%3agcch%3ameeting_a42a%40thread.v2/0",
    )
  }

  it "takes the join link as the place when the invite leaves it empty" do
    invite = described_class.parse(teams)

    expect(invite[:location])
      .to eq("https://gov.teams.microsoft.us/l/meetup-join/19%3agcch%3ameeting_a42a%40thread.v2/0")
  end

  it "takes the link the meeting states over the program it names as the room" do
    invite = described_class.parse(
      outlook.sub(
        "LOCATION;LANGUAGE=en-US:+1 385-259-9640",
        "LOCATION;LANGUAGE=en-US:Microsoft Teams Meeting\r\n" \
        "X-MICROSOFT-SKYPETEAMSMEETINGURL:https://teams.microsoft.com/l/meetup-join/19%3ameeting_b7",
      ),
    )

    expect(invite[:location]).to eq("https://teams.microsoft.com/l/meetup-join/19%3ameeting_b7")
  end

  # An organizer's words are full of links - the posting, the calendar's own
  # "view event", a reschedule page. None of them moves a stated room.
  it "leaves a stated room alone whatever the words link to" do
    invite = described_class.parse(
      teams.sub("LOCATION;LANGUAGE=en-US:", "LOCATION;LANGUAGE=en-US:2600 W Executive Pkwy"),
    )

    expect(invite[:location]).to eq("2600 W Executive Pkwy")
  end

  it "has no place for a booking that names none" do
    expect(described_class.parse(outlook.sub("LOCATION;LANGUAGE=en-US:+1 385-259-9640", ""))[:location])
      .to be_nil
  end

  # EVERY Exchange invite carries RRULEs that are nothing to do with the
  # meeting: each VTIMEZONE block above the event states when a daylight-saving
  # rule began. Read as the event's own, a one-off catch-up would repeat on the
  # first Sunday in November for the rest of time.
  it "takes no repeat rule from the time zone blocks above the event" do
    with_zone_rule = outlook.sub(
      "DTSTART:16010101T020000",
      "DTSTART:16010101T020000\r\nRRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=1SU;BYMONTH=11",
    )

    expect(described_class.parse(with_zone_rule)[:recurrence]).to be_nil
  end

  it "reads the repeat rule the meeting states, and the dates struck off it" do
    invite = described_class.parse(
      outlook.sub(
        "BEGIN:VEVENT",
        "BEGIN:VEVENT\r\nRRULE:FREQ=WEEKLY;BYDAY=MO,WE\r\n" \
        "EXDATE;TZID=Eastern Standard Time:20261104T133000",
      ),
    )

    expect(invite[:recurrence]).to eq(
      ["RRULE:FREQ=WEEKLY;BYDAY=MO,WE", "EXDATE;TZID=Eastern Standard Time:20261104T133000"],
    )
  end

  # Which morning of the series this one is about.
  it "reads the occurrence a single instance replaces" do
    invite = described_class.parse(
      outlook.sub("BEGIN:VEVENT", "BEGIN:VEVENT\r\nRECURRENCE-ID:20261027T173000Z"),
    )

    expect(invite[:occurrence]).to eq(Time.utc(2026, 10, 27, 17, 30))
  end

  it "keeps no guest there is no way to reach" do
    invite = described_class.parse(outlook.sub("BEGIN:VEVENT", "BEGIN:VEVENT\r\nATTENDEE;CN=Big Room:mailto:"))

    expect(invite[:attendees]).to be_empty
  end
end
