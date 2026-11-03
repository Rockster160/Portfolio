require "rails_helper"

# A synced invite answers through Google. An invite that came as a .ics has no
# API behind it: the only thing holding the meeting is the organizer's own
# calendar, so the answer goes back the way the invite came.
RSpec.describe Emails::InviteReply do
  let(:user) { create(:user) }
  let(:agenda) { user.agendas.order(:id).first }
  let(:item) {
    agenda.agenda_items.create!(
      name:     "Interview: Acme",
      kind:     :event,
      start_at: Time.utc(2026, 11, 3, 15, 0),
      end_at:   Time.utc(2026, 11, 3, 15, 45),
      metadata: {
        "organizer" => { "email" => "erin@acme.test" },
        "invite"    => {
          "uid"          => "booking-9f2@calendly.com",
          "sequence"     => 3,
          "replying_as"  => "rocco@ardesian.com",
          "sending_from" => "rocco@ardesian.com",
        },
      },
    )
  }

  def reply(response)
    described_class.call(item: item, response: response)
  end

  def calendar_part(message)
    message.all_parts.find { |part| part.content_type.to_s.include?("text/calendar") }
  end

  it "answers the organizer, as the address they invited" do
    message = reply("accepted")

    expect(message.to).to eq(["erin@acme.test"])
    expect(message.from).to eq(["rocco@ardesian.com"])
  end

  # What the organizer's calendar reads is the REPLY part, quoting the
  # organizer's own sequence: an older one reads as an answer to a meeting that
  # has since moved. SENT-BY is left off when the invited address is the sender.
  it "carries the event back with the answer on it", :aggregate_failures do
    part = calendar_part(reply("declined"))

    expect(part.content_type).to include("method=REPLY")
    expect(part.decoded).to include(
      "METHOD:REPLY",
      "UID:booking-9f2@calendly.com",
      "SEQUENCE:3",
      "ATTENDEE;PARTSTAT=DECLINED:mailto:rocco@ardesian.com",
    )
    expect(part.decoded).not_to include("SENT-BY")
  end

  it "files the copy it sent" do
    expect { reply("accepted") }.to change { user.emails.where(direction: :outbound).count }.by(1)
  end

  # An invite to the Gmail address has to be answered AS that address, and mail
  # can only leave from a domain we control. SENT-BY is the iCalendar way of
  # saying the two are not the same person.
  describe "answering as an address we cannot send from" do
    before do
      item.update!(metadata: item.metadata.merge(
        "invite" => item.invite_details.merge(
          "replying_as"  => "rocco11nicholls@gmail.com",
          "sending_from" => "contact@ardesian.com",
        ),
      ))
    end

    it "sends from the domain and answers in the invited name" do
      message = reply("accepted")

      expect(message.from).to eq(["contact@ardesian.com"])
      expect(calendar_part(message).decoded).to include(
        'ATTENDEE;PARTSTAT=ACCEPTED;SENT-BY="mailto:contact@ardesian.com":mailto:rocco11nicholls@gmail.com',
      )
    end
  end

  it "says so rather than going quiet when there is nobody to answer" do
    item.update!(metadata: item.metadata.merge("organizer" => nil))

    expect { reply("accepted") }.to raise_error(described_class::Undeliverable, /no organizer/)
  end

  it "says so when the invite names no address of his" do
    item.update!(metadata: item.metadata.merge("invite" => { "uid" => "x" }))

    expect { reply("accepted") }.to raise_error(described_class::Undeliverable, /no address of yours/)
  end
end
