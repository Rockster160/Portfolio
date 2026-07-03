require "rails_helper"

RSpec.describe "Excluded-date sweep" do
  before do
    allow(::AgendaTravelChainSyncWorker).to receive(:perform_async)
    allow(::Jil).to receive(:trigger)
    allow(::Jil::Schedule).to receive(:add_job)
    allow(::Jil::Schedule).to receive(:update)
  end

  let(:user) { create(:user) }
  let(:agenda) { create(:agenda, user: user) }
  let(:excluded_date) { Date.new(2026, 7, 3) }
  let(:zone) { ActiveSupport::TimeZone["America/Denver"] }
  let(:sched) {
    create(:agenda_schedule,
      agenda: agenda,
      kind: :event,
      duration_minutes: 30,
      start_time: "15:30",
      recurrence: { "freq" => "weekdays" },
      starts_on: excluded_date - 30)
  }

  def build_trigger(item, offset_seconds:, name:)
    ::ScheduledTrigger.create!(
      user_id:        user.id,
      trigger:        "test-trigger",
      execute_at:     item.start_at + offset_seconds,
      offset_seconds: offset_seconds,
      name:           name,
      source_item_id: item.id,
      data:           {},
    )
  end

  describe "AgendaSchedule#add_excluded_date!" do
    it "cancels a materialized item on the excluded date and purges its pending triggers" do
      item = create(:agenda_item,
        agenda: agenda,
        agenda_schedule: sched,
        kind: :event,
        name: "Occurrence",
        start_at: zone.local(2026, 7, 3, 15, 30),
        end_at: zone.local(2026, 7, 3, 16, 0),
        original_start_at: zone.local(2026, 7, 3, 15, 30))
      pending = build_trigger(item, offset_seconds: -45.minutes, name: "🌅 Slow fade")
      already_fired = build_trigger(item, offset_seconds: -60.minutes, name: "past")
      already_fired.update_columns(started_at: 1.hour.ago)

      sched.add_excluded_date!(excluded_date)

      item.reload
      expect(item.status).to eq("cancelled")
      expect(item.cancelled_at).to be_present
      expect(::ScheduledTrigger.exists?(pending.id)).to be false
      expect(::ScheduledTrigger.exists?(already_fired.id)).to be true
    end

    it "sweeps detached overrides that kept their original_start_at" do
      detached = create(:agenda_item,
        agenda: agenda,
        agenda_schedule: sched,
        kind: :event,
        name: "Detached override",
        start_at: zone.local(2026, 7, 3, 15, 30),
        end_at: zone.local(2026, 7, 3, 16, 0),
        original_start_at: zone.local(2026, 7, 3, 15, 30),
        detached_at: 1.day.ago)
      trig = build_trigger(detached, offset_seconds: -300, name: "prestandup")

      sched.add_excluded_date!(excluded_date)

      detached.reload
      expect(detached.status).to eq("cancelled")
      expect(::ScheduledTrigger.exists?(trig.id)).to be false
    end

    it "leaves items on other dates untouched" do
      other_date = zone.local(2026, 7, 6, 15, 30)
      item = create(:agenda_item,
        agenda: agenda,
        agenda_schedule: sched,
        kind: :event,
        start_at: other_date,
        end_at: other_date + 30.minutes,
        original_start_at: other_date)
      trig = build_trigger(item, offset_seconds: -600, name: "unrelated")

      sched.add_excluded_date!(excluded_date)

      item.reload
      expect(item.status).to eq("confirmed")
      expect(::ScheduledTrigger.exists?(trig.id)).to be true
    end
  end

  describe "AgendaItem status → cancelled" do
    it "purges pending derived triggers when status flips independently" do
      item = create(:agenda_item,
        agenda: agenda,
        kind: :event,
        start_at: zone.local(2026, 7, 10, 9, 0),
        end_at: zone.local(2026, 7, 10, 9, 30))
      pending = build_trigger(item, offset_seconds: -900, name: "warmup")

      item.update!(status: :cancelled, cancelled_at: Time.current)

      expect(::ScheduledTrigger.exists?(pending.id)).to be false
    end
  end
end
