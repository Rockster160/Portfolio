require "rails_helper"

# FeatureRequest 5. The suite number used to arrive five minutes before the
# appointment started (prod tasks 347/348), and Rocco is routinely there before
# that - traffic, paperwork, leaving early on purpose. So it is said on ARRIVAL
# now, with the old schedule kept as the backstop for an arrival nobody reports.
#
# The whole reason this is Ruby: Jil has no geometry. No distance, no geocode,
# no coordinate type - so "is this arrival AT that appointment" is a question
# the task cannot ask, and a version that fired on any arrival would read out a
# clinic's suite number in the supermarket car park.
RSpec.describe SuiteOnArrival do
  let(:user)    { create(:user) }
  let!(:agenda) { Agenda.create!(user: user, name: "Mine") }
  let(:clinic)  { [40.5200, -111.8900] }
  let(:away)    { [40.7608, -111.8910] }

  before do
    # Nothing here may reach Google. A location that resolves to a coordinate
    # is the ONE thing being tested, so it is handed over directly.
    allow_any_instance_of(AddressBook).to receive(:coords_for_location) { |_ab, loc|
      loc.to_s.include?("State St") ? clinic : nil
    }
    allow(::LocationCache).to receive(:last_coord).and_return(nil)
  end

  def appointment(name: "Eye Follow Up", at: 45.minutes.from_now, location: "11820 S State St Suite 320 Draper, UT")
    AgendaItem.create!(
      agenda: agenda, name: name, kind: :event,
      start_at: at, end_at: at + 30.minutes, location: location,
    )
  end

  def arrive(coord = clinic, action: :arrived)
    described_class.call({ action: action, lat: coord[0], lng: coord[1] }, user: user)
  end

  describe "arriving at the appointment" do
    it "hands back the name and the suite" do
      item = appointment

      expect(arrive).to eq(
        "name" => "Eye Follow Up", "suite" => "Suite 320", "event_id" => item.id,
      )
    end

    it "reads a # number too" do
      appointment(location: "100 E Center St #1300, Provo UT")
      allow_any_instance_of(AddressBook).to receive(:coords_for_location).and_return(clinic)

      expect(arrive["suite"]).to eq("#1300")
    end

    it "reads the other words for one" do
      appointment(location: "1 Health Way Unit B, Draper UT")
      allow_any_instance_of(AddressBook).to receive(:coords_for_location).and_return(clinic)

      expect(arrive["suite"]).to eq("Unit B")
    end

    # The request in one sentence: early is the case this exists for.
    it "says it however early they are" do
      appointment(at: 2.hours.from_now)

      expect(arrive["suite"]).to eq("Suite 320")
    end

    # And the case where the traffic won.
    it "still says it when they are late" do
      appointment(at: 10.minutes.ago)

      expect(arrive["suite"]).to eq("Suite 320")
    end
  end

  describe "arrivals it must stay quiet for" do
    it "says nothing when the appointment has no suite in it" do
      appointment(location: "11820 S State St Draper, UT")

      expect(arrive).to eq({})
    end

    # The failure the coordinate check exists to prevent.
    it "says nothing when they arrived somewhere else entirely" do
      appointment

      expect(arrive(away)).to eq({})
    end

    it "says nothing on a departure" do
      appointment

      expect(arrive(action: :departed)).to eq({})
    end

    it "says nothing when the appointment is hours off yet" do
      appointment(at: 6.hours.from_now)

      expect(arrive).to eq({})
    end

    it "ignores one that was cancelled" do
      appointment.update!(cancelled_at: Time.current)

      expect(arrive).to eq({})
    end

    it "ignores one already marked done" do
      appointment.update!(completed_at: Time.current)

      expect(arrive).to eq({})
    end

    it "says nothing when there is no position on the report and none cached" do
      appointment

      expect(described_class.call({ action: :arrived }, user: user)).to eq({})
    end
  end

  # A queued report replayed out of a dead zone can arrive with no coordinate
  # on it at all. The phone's last known position is what the report was about.
  it "falls back to the last known position when the report carries none" do
    appointment
    allow(::LocationCache).to receive(:last_coord).and_return(clinic)

    expect(described_class.call({ action: :arrived }, user: user)["suite"]).to eq("Suite 320")
  end

  describe "the scheduled copy" do
    let!(:item) { appointment }
    let!(:scheduled) {
      user.scheduled_triggers.create!(
        trigger: "suite-reminder", execute_at: 40.minutes.from_now, source_item: item,
        name: "suite-reminder", offset_seconds: -300, data: {},
      )
    }

    before { allow(::Jil::Schedule).to receive(:cancel) }

    # Said once. The -5 minute schedule is the backstop for an arrival nobody
    # reported, and once this has fired it is a repeat rather than a backstop.
    it "is taken off the clock once the arrival has said it" do
      arrive

      expect(ScheduledTrigger.where(id: scheduled.id)).not_to exist
      expect(::Jil::Schedule).to have_received(:cancel)
    end

    # The backstop has to survive every arrival that ISN'T this appointment, or
    # a stop at the shops on the way would silently disarm it.
    it "is left alone when they arrived somewhere else" do
      arrive(away)

      expect(ScheduledTrigger.where(id: scheduled.id)).to exist
    end
  end

  # Another person's arrival must never read the owner's calendar. The Custom
  # method is gated on `user.me?` for the same reason every other one there is.
  it "is only reachable from Jil as the owner" do
    expect(File.read(Rails.root.join("app/service/jil/methods/custom.rb")))
      .to match(/suite_on_arrival.*\n.*@jil\.user\.me\?/)
  end
end
