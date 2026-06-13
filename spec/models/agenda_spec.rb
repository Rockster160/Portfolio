require "rails_helper"

RSpec.describe Agenda do
  let(:user) { create(:user) }

  it "creates with parameterized_name and default color" do
    agenda = described_class.create!(user: user, name: "My Work Stuff")
    expect(agenda.parameterized_name).to eq("my-work-stuff")
    expect(agenda.color).to eq(Agenda::DEFAULT_COLOR)
  end

  it "uniqueness of parameterized_name scoped to user" do
    described_class.create!(user: user, name: "Work")
    dup = described_class.new(user: user, name: "Work")
    expect(dup).not_to be_valid

    other_user = create(:user, phone: "5550000002")
    other = described_class.new(user: other_user, name: "Work")
    expect(other).to be_valid
  end

  describe "#items_for" do
    let(:agenda) { create(:agenda, user: user) }

    it "returns persisted rows on the matching date" do
      target_date = Date.current + 30.days
      target = create(:agenda_item, agenda: agenda, kind: "task",
        start_at: Time.zone.local(target_date.year, target_date.month, target_date.day, 8, 0))
      _other = create(:agenda_item, agenda: agenda, kind: "task",
        start_at: Time.zone.local(target_date.year, target_date.month, target_date.day, 8, 0) + 2.days)
      expect(agenda.items_for(target_date).to_a).to eq([target])
    end

    it "merges in phantoms from each matching schedule" do
      sched = create(:agenda_schedule, agenda: agenda, name: "Standup",
        kind: "task", start_time: "09:00",
        recurrence: { "freq" => "daily" }, starts_on: Date.current)
      items = agenda.items_for(Date.current + 50.days)
      phantom = items.find(&:phantom?)
      expect(phantom).to be_present
      expect(phantom.name).to eq("Standup")
      expect(phantom.agenda_schedule_id).to eq(sched.id)
    end

    it "renders schedules 100 years into the future without materialization" do
      create(:agenda_schedule, agenda: agenda, name: "Birthday",
        kind: "event", start_time: "10:00", duration_minutes: 60,
        recurrence: { "freq" => "monthly", "by_month_day" => [15] },
        starts_on: Date.current)

      future = Date.current.change(day: 15) + 100.years
      items = agenda.items_for(future)
      expect(items.size).to eq(1)
      expect(items.first).to be_phantom
      expect(AgendaItem.count).to eq(0)
    end

    it "prefers the real row over a phantom when a recurring instance has been materialized" do
      sched = create(:agenda_schedule, agenda: agenda, kind: "task",
        recurrence: { "freq" => "daily" }, starts_on: Date.current)
      target = Date.current + 3.days
      sched.phantom_for(target).materialize!(name: "Customized")

      items = agenda.items_for(target)
      expect(items.size).to eq(1)
      expect(items.first.name).to eq("Customized")
      expect(items.first).not_to be_phantom
    end

    it "suppresses the phantom on a detached override's original_start_at date even when the override now lives on a different day" do
      Timecop.freeze(Time.zone.local(2026, 6, 1, 10, 0)) do
        sched = create(:agenda_schedule, agenda: agenda, kind: "event",
          name: "Sync", start_time: "10:00", duration_minutes: 30,
          recurrence: { "freq" => "monthly", "by_set_pos" => 3, "by_day" => ["tue"] },
          starts_on: Date.new(2026, 3, 17))

        # User moved the Jun 16 (3rd Tue) occurrence to Jun 15 (Mon).
        moved_to = Time.zone.local(2026, 6, 15, 9, 0)
        original = Time.zone.local(2026, 6, 16, 10, 0)
        override = create(:agenda_item, agenda: agenda, kind: "event",
          agenda_schedule: sched, detached_at: Time.current,
          original_start_at: original,
          start_at: moved_to, end_at: moved_to + 30.minutes,
          name: "Sync")

        june_items = agenda.items_for_range(Date.new(2026, 6, 14), Date.new(2026, 6, 17))
        # Should see exactly ONE Sync: the override on Mon Jun 15. No phantom on Jun 16.
        sync_items = june_items.select { |i| i.name == "Sync" }
        expect(sync_items.map(&:id)).to eq([override.id])
        expect(sync_items.none?(&:phantom?)).to be true
      end
    end
  end

  describe "#carry_over_items" do
    let(:agenda) { create(:agenda, user: user) }

    it "returns past-due uncompleted tasks only (not events)" do
      Timecop.freeze(Time.zone.local(2026, 5, 13, 10, 0)) do
        overdue_task = create(:agenda_item, agenda: agenda, kind: "task",
          start_at: 2.days.ago, completed_at: nil)
        _completed = create(:agenda_item, agenda: agenda, kind: "task",
          start_at: 2.days.ago, completed_at: 1.day.ago)
        _past_event = create(:agenda_item, agenda: agenda, kind: "event",
          start_at: 2.days.ago, end_at: 2.days.ago + 1.hour)
        _today_task = create(:agenda_item, agenda: agenda, kind: "task",
          start_at: Time.current)

        expect(agenda.carry_over_items.to_a).to eq([overdue_task])
      end
    end

    it "keeps a carry-over task that was completed today (so it stays crossed-out, not vanishing)" do
      Timecop.freeze(Time.zone.local(2026, 5, 13, 10, 0)) do
        completed_today = create(:agenda_item, agenda: agenda, kind: "task",
          start_at: 2.days.ago, completed_at: Time.current)
        still_open = create(:agenda_item, agenda: agenda, kind: "task",
          start_at: 1.day.ago, completed_at: nil)
        _completed_yesterday = create(:agenda_item, agenda: agenda, kind: "task",
          start_at: 3.days.ago, completed_at: 1.day.ago)

        expect(agenda.carry_over_items.to_a).to match_array([completed_today, still_open])
      end
    end
  end
end
