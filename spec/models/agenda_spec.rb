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
  end
end
