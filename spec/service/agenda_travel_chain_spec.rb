require "rails_helper"

# Phase 1 wiring smoke. Confirms every public surface loads cleanly and the
# basic chain detection behaves end-to-end against stubbed AddressBook calls.
# Deep edge-case coverage lives in the focused specs alongside each module.
RSpec.describe AgendaTravelChain do
  describe "module-level surface" do
    it "exposes run_for / refresh_for" do
      expect(described_class).to respond_to(:run_for)
      expect(described_class).to respond_to(:refresh_for)
    end

    it "the worker loads with sidekiq dedup on" do
      expect(AgendaTravelChainSyncWorker.sidekiq_options).to include("lock" => :until_executed)
    end

    it "the Custom Jil method dispatches to refresh_travel_time" do
      methods = Jil::Methods::Custom.instance_methods(false)
      expect(methods).to include(:refresh_travel_time)
    end
  end

  describe ".reset_and_recompute_for" do
    let(:user) { create(:user) }
    let(:agenda) { create(:agenda, user: user) }
    let(:home_address) { instance_double("Address", street: "Home St", loc: [40.5, -111.9]) }
    let(:address_book) { instance_double("AddressBook") }

    before do
      allow_any_instance_of(::User).to receive(:address_book).and_return(address_book)
      allow(address_book).to receive(:home).and_return(home_address)
      allow(address_book).to receive(:match_contact).and_return(nil)
      allow(address_book).to receive(:geocode) { |addr| [40.0 + addr.to_s.length * 0.001, -111.0] }
      allow(address_book).to receive(:traveltime_seconds).and_return(900)
      allow(::AddressBook).to receive(:non_travelable?).and_return(false)
    end

    def make_event(start_at:, agenda_schedule: nil, extra_meta: {})
      evt = agenda.agenda_items.create!(
        name: "TMS",
        kind: :event,
        start_at: start_at,
        end_at: start_at + 1.hour,
        location: "Office",
        agenda_schedule: agenda_schedule,
      )
      if extra_meta.any?
        evt.update_columns(
          metadata: evt.metadata.merge(extra_meta),
          updated_at: ::Time.current,
        )
        evt.reload
      end
      evt
    end

    it "scrubs legacy top-level travel keys and the nested travel hash, preserving unrelated metadata" do
      start_at = 2.days.from_now.beginning_of_hour
      evt = make_event(start_at: start_at, extra_meta: {
        "travel_minutes"  => 0,
        "travel_location" => "Stale Lehi",
        "travel"          => { "stale" => true },
        "suite_reminder"  => { "fired" => true },
      })

      described_class.reset_and_recompute_for(evt)
      evt.reload

      expect(evt.metadata).not_to have_key("travel_minutes")
      expect(evt.metadata).not_to have_key("travel_location")
      expect(evt.metadata["travel"]).to be_present
      expect(evt.metadata["travel"]["stale"]).to be_nil
      expect(evt.metadata["travel"]["travel_seconds"]).to eq(900)
      expect(evt.metadata["suite_reminder"]).to eq("fired" => true)
    end

    it "cascades from an AgendaSchedule to its future items and the schedule's own metadata" do
      schedule = ::AgendaSchedule.create!(
        agenda: agenda,
        name: "TMS",
        kind: :event,
        location: "Office",
        start_time: "09:00:00",
        duration_minutes: 60,
        recurrence: { freq: "daily" },
        starts_on: 1.month.ago.to_date,
        metadata: {
          "travel_minutes" => 0,
          "travel" => { "stale" => true },
          "kept"   => "yes",
        },
      )
      future_evt = make_event(
        start_at: 2.days.from_now.beginning_of_hour,
        agenda_schedule: schedule,
        extra_meta: { "travel_minutes" => 0, "travel" => { "stale" => true } },
      )
      past_evt = make_event(
        start_at: 2.days.ago.beginning_of_hour,
        agenda_schedule: schedule,
        extra_meta: { "travel" => { "kept_because_past" => true } },
      )

      described_class.reset_and_recompute_for(schedule)
      schedule.reload
      future_evt.reload
      past_evt.reload

      expect(schedule.metadata).not_to have_key("travel_minutes")
      expect(schedule.metadata["kept"]).to eq("yes")

      expect(future_evt.metadata).not_to have_key("travel_minutes")
      expect(future_evt.metadata["travel"]).to be_present
      expect(future_evt.metadata["travel"]["stale"]).to be_nil
      expect(future_evt.metadata["travel"]["travel_seconds"]).to eq(900)

      expect(past_evt.metadata["travel"]).to eq("kept_because_past" => true)
    end

    it "handles an Agenda by sweeping schedules + future items" do
      schedule = ::AgendaSchedule.create!(
        agenda: agenda,
        name: "TMS",
        kind: :event,
        location: "Office",
        start_time: "09:00:00",
        duration_minutes: 60,
        recurrence: { freq: "daily" },
        starts_on: 1.month.ago.to_date,
        metadata: { "travel_minutes" => 0 },
      )
      future_evt = make_event(
        start_at: 1.day.from_now.beginning_of_hour,
        agenda_schedule: schedule,
        extra_meta: { "travel_minutes" => 0 },
      )

      described_class.reset_and_recompute_for(agenda)
      schedule.reload
      future_evt.reload

      expect(schedule.metadata).not_to have_key("travel_minutes")
      expect(future_evt.metadata).not_to have_key("travel_minutes")
      expect(future_evt.metadata["travel"]).to be_present
    end

    it "raises for unsupported record types" do
      expect {
        described_class.reset_and_recompute_for(user)
      }.to raise_error(ArgumentError, /reset_and_recompute_for cannot handle/)
    end
  end
end
