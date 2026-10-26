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
end
