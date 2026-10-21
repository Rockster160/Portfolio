require "rails_helper"

RSpec.describe ByteInterviewPrep::HeadsUp do
  let(:user)   { User.me }
  let(:tz)     { ActiveSupport::TimeZone["America/Denver"] }
  let(:agenda) { create(:agenda, user: user) }
  let(:job)    { user.job_applications.create!(company: "Bluestaq", role: "Principal Engineer") }
  let(:start)  { tz.parse("2026-10-20 12:00:00") }
  let(:said)   { ByteConversation.for_self_initiated(user).byte_messages.order(:id).last }

  # Ours: written by a job beat, the application link on the first line.
  def ours(notes: nil, location: nil)
    create(
      :agenda_item,
      agenda: agenda, kind: :event, name: "Interview: Bluestaq", location: location,
      start_at: start, end_at: start + 1.hour, notes: [job.interview_url, notes].compact.join("\n\n")
    )
  end

  # Theirs: the company's synced invite, the same minute.
  def invite(name: "Interview with Bluestaq US External", location: nil, notes: nil, at: start)
    create(
      :agenda_item,
      agenda: agenda, kind: :event, name: name, location: location, notes: notes,
      start_at: at, end_at: at + 1.hour
    )
  end

  before do
    allow(Rails.env).to receive(:production?).and_return(true)
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(BuddyDeliverWorker).to receive(:perform_async)
    allow(WebPushNotifications).to receive(:send_to_byte)
    ByteConversation.for_self_initiated(user) || user.byte_conversations.create!(name: "Buddy", mode: :buddy)
  end

  describe ".how" do
    it "takes the join link off the company's invite, where Teams puts it" do
      item = ours(notes: "Interview: Technical Panel Interview")
      teams = "https://gov.teams.microsoft.us/l/meetup-join/19%3agcch%3ameeting_a42a%40thread.v2/0"
      invite(location: teams, notes: "Join the Microsoft Teams meeting: #{teams}")

      expect(described_class.how(item, job, user)).to eq({ kind: :link, url: teams })
    end

    it "finds a link written into our own notes, ahead of the invite's" do
      item = ours(notes: "Call details:\n- Meeting Link: https://meet.google.com/tfi-tdsp-zik.\n")
      invite(location: "https://meet.google.com/zzz-zzzz-zzz")

      expect(described_class.how(item, job, user)[:url]).to eq("https://meet.google.com/tfi-tdsp-zik")
    end

    # A Google invite's description is full of links - the dial-in, the
    # "view event" - and only one of them is the call.
    it "skips the links that are not the call" do
      item = ours
      invite(
        location: nil,
        notes:    "More phone numbers\nhttps://tel.meet/moh-hbtd-mwh?pin=83\n" \
                  "https://calendar.google.com/calendar/event?action=VIEW\n" \
                  "Join: https://icapitalnetwork.zoom.us/j/9413?pwd=Jh",
      )

      expect(described_class.how(item, job, user)[:url]).to eq("https://icapitalnetwork.zoom.us/j/9413?pwd=Jh")
    end

    it "ignores another event at the same minute that is not this company's" do
      item = ours
      invite(name: "Tech Stand-Up", location: "https://meet.google.com/abc-defg-hij")

      expect(described_class.how(item, job, user)).to eq({ kind: :phone, said: false })
    end

    # Google attaches a Meet to every event it makes; an onsite still has one.
    it "is in person when our row carries a street address, Meet link or not" do
      item = ours(location: "2600 W Executive Pkwy, Suite 550, Lehi, UT 84043")
      invite(location: "https://meet.google.com/efr-kwqe-kvp")

      expect(described_class.how(item, job, user)).to eq({ kind: :in_person })
    end

    it "is a phone call when the booking says they'll call" do
      item = ours(notes: "Interview Type: Phone call-I will call the phone number provided")

      expect(described_class.how(item, job, user)).to eq({ kind: :phone, said: true })
    end

    # Google keeps an invite from an unknown sender off the calendar, so there
    # is no twin; the invite mail is still filed onto the application.
    describe "when the invite only reached the application" do
      def note!(body, at:)
        job.notes.create!(body: body, occurred_at: at)
      end

      it "takes the link off the invite note naming this interview's day" do
        item = ours
        note!("Interview with Bluestaq\nTuesday Oct 20, 2026 ⋅ 12pm – 1pm\n" \
              "Join Google Meet: https://meet.google.com/dip-asws-sgw", at: start - 1.day)

        expect(described_class.how(item, job, user)).to eq({ kind: :link, url: "https://meet.google.com/dip-asws-sgw" })
      end

      it "leaves an earlier round's invite alone" do
        item = ours
        note!("Recruiter screen\nThursday Oct 1, 2026 ⋅ 9am\nhttps://meet.google.com/old-link-xyz", at: start - 3.weeks)

        expect(described_class.how(item, job, user)).to eq({ kind: :phone, said: false })
      end
    end

    it "does not take a phone number in the location for an address" do
      item = ours(location: "801-372-5097")

      expect(described_class.how(item, job, user)[:kind]).to eq(:phone)
    end
  end

  describe ".dispatch" do
    it "sends the link" do
      item = ours
      invite(location: "https://meet.google.com/moh-hbtd-mwh")

      expect(described_class.dispatch(user, item.id)).to eq(:link)
      expect(said.body).to eq("Bluestaq starts in 2 minutes - here's the link.\n\nhttps://meet.google.com/moh-hbtd-mwh")
      expect(said.metadata).to include("source" => "interview_join", "agenda_item_id" => item.id)
      expect(WebPushNotifications).to have_received(:send_to_byte)
    end

    it "warns to watch the phone when it's a call" do
      item = ours(notes: "Phone call - I will call the phone number provided")

      expect(described_class.dispatch(user, item.id)).to eq(:phone)
      expect(said.body).to eq("Bluestaq starts in 2 minutes - it's a phone call, keep your phone close.")
    end

    it "says it's probably a call when there is nothing to join" do
      item = ours

      expect(described_class.dispatch(user, item.id)).to eq(:phone)
      expect(said.body).to include("no link on the booking")
    end

    it "sends nothing for an onsite" do
      item = ours(location: "2600 W Executive Pkwy, Lehi, UT")

      expect { described_class.dispatch(user, item.id) }.not_to(change(ByteMessage, :count))
      expect(described_class.dispatch(user, item.id)).to eq(:in_person)
    end

    # Both rows of one interview carry a trigger; only ours speaks.
    it "stays quiet for the company's own invite" do
      invite_row = invite(location: "https://meet.google.com/moh-hbtd-mwh")

      expect(described_class.dispatch(user, invite_row.id)).to eq(:not_an_interview)
    end

    # A split interview: ours is booked for the first session only, and the
    # company sent a second invite with its own link.
    describe "a second session with no row of ours" do
      let!(:first) { ours }

      it "sends that invite's own link" do
        teams = "https://teams.microsoft.com/l/meetup-join/second"
        second = invite(location: teams, at: start + 75.minutes)

        expect(described_class.dispatch(user, second.id)).to eq(:link)
        expect(said.body).to eq("Bluestaq starts in 2 minutes - here's the link.\n\n#{teams}")
        expect(said.metadata).to include("agenda_item_id" => second.id)
      end

      it "stays quiet for an invite from another company" do
        other = invite(name: "Interview with Acme", location: "https://meet.google.com/abc", at: start + 75.minutes)

        expect(described_class.dispatch(user, other.id)).to eq(:not_an_interview)
      end

      it "stays quiet for the twin of our own row" do
        twin = invite(location: "https://meet.google.com/moh-hbtd-mwh")

        expect(described_class.dispatch(user, twin.id)).to eq(:not_an_interview)
      end
    end

    it "sends once when the trigger fires twice" do
      item = ours

      described_class.dispatch(user, item.id)
      expect { described_class.dispatch(user, item.id) }.not_to(change(ByteMessage, :count))
      expect(described_class.dispatch(user, item.id)).to eq(:already_sent)
    end

    it "does nothing outside production" do
      allow(Rails.env).to receive(:production?).and_return(false)

      expect(described_class.dispatch(user, ours.id)).to eq(:not_production)
    end
  end
end
