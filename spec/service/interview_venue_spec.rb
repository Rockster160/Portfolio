require "rails_helper"

RSpec.describe InterviewVenue do
  let(:user) { User.me }
  let(:job)  { user.job_applications.create!(company: "Neighbor", role: "Software Engineer") }
  let(:at)   { 5.days.from_now.change(min: 30) }

  let(:address_mail) {
    <<~TXT
      Following up on our conversation, I'm excited to confirm the details for your upcoming
      onsite FINAL interview for the Senior Software Engineer position at Neighbor!

      I have you all set for your onsite interviews on 10/21 at 11:30.

      Office Address: 2600 W Executive Pkwy, Suite 550, Lehi, UT 84043.

      Please make sure to arrive 5 minutes early. Text me (801-372-5097) on arrival.
    TXT
  }

  let(:invite_text) {
    <<~TXT
      Onsite Interview with Neighbor
      Join with Google Meet
      https://meet.google.com/moh-hbtd-mwh?hs=224
    TXT
  }

  before do
    create(:agenda, user: user)
    allow_any_instance_of(Agenda).to receive(:broadcast!)
  end

  def book(body)
    job.notes.create!(tag: :scheduled, body: body, follow_up_at: at, occurred_at: 1.minute.ago)
  end

  def row(note)
    AgendaItem.find(note.reload.agenda_item_id)
  end

  # Neighbor's shape: the invite is the booking, the address is the mail
  # eight seconds behind it.
  it "fills the booking's row from the address mail that lands after it" do
    booking = book(invite_text)
    expect(row(booking).location).to be_blank

    job.notes.create!(tag: :note, body: address_mail, occurred_at: Time.current)

    expect(row(booking).location).to eq("2600 W Executive Pkwy, Suite 550, Lehi, UT 84043")
  end

  it "fills it straight away when the booking itself carries the address" do
    booking = book("WHERE TO GO: 2600 W Executive Pkwy, Suite 550, Lehi, UT 84043. Two hours onsite.")

    expect(row(booking).location).to eq("2600 W Executive Pkwy, Suite 550, Lehi, UT 84043")
  end

  it "reads a Utah grid address" do
    booking = book("In-person interview at our office: 1234 S 500 E, Salt Lake City, UT 84105")

    expect(row(booking).location).to eq("1234 S 500 E, Salt Lake City, UT 84105")
  end

  it "never overwrites a location already on the row" do
    booking = book(invite_text)
    row(booking).update!(location: "Front desk, ask for Beach")

    job.notes.create!(tag: :note, body: address_mail, occurred_at: Time.current)

    expect(row(booking).location).to eq("Front desk, ask for Beach")
  end

  it "leaves a video interview alone, address in the signature or not" do
    booking = book("Video call via Google Meet.\n\nAcme Inc, 100 Main St, Denver, CO 80202")

    expect(row(booking).location).to be_blank
  end

  it "does not take a virtual onsite for a trip to the office" do
    booking = book("Your virtual onsite is confirmed. Acme HQ, 100 Main St, Denver, CO 80202")

    expect(row(booking).location).to be_blank
  end

  # The posting says "on-site" about the JOB, and the application quotes it.
  it "ignores the posting quoted on the application" do
    job.notes.create!(tag: :applied, body: "On-site role. Office at 100 Main St, Denver, CO", occurred_at: 1.hour.ago)
    booking = book("Video call via Google Meet.")

    expect(row(booking).location).to be_blank
  end

  it "ignores a note from weeks away from the booking" do
    job.notes.create!(tag: :note, body: address_mail, occurred_at: 3.weeks.ago)
    booking = book(invite_text)

    expect(row(booking).location).to be_blank
  end

  it "leaves an interview already past alone" do
    booking = job.notes.create!(
      tag: :scheduled, body: invite_text, follow_up_at: 2.days.ago, occurred_at: 4.days.ago,
    )
    job.notes.create!(tag: :note, body: address_mail, occurred_at: 4.days.ago)

    expect(row(booking).location).to be_blank
  end
end
