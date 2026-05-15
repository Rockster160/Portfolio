require "rails_helper"

RSpec.describe "AgendaItem.query — bare-token state filters" do
  let(:user) { create(:user) }
  let(:agenda) { create(:agenda, user: user) }

  let(:overdue_task) {
    create(:agenda_item, agenda: agenda, kind: "task",
      start_at: 2.days.ago, completed_at: nil, name: "Overdue Task")
  }
  let(:completed_task) {
    create(:agenda_item, agenda: agenda, kind: "task",
      start_at: 2.days.ago, completed_at: 1.day.ago, name: "Done Task")
  }
  let(:upcoming_event) {
    create(:agenda_item, agenda: agenda, kind: "event",
      start_at: 2.days.from_now, end_at: 2.days.from_now + 1.hour, name: "Future Event")
  }
  let(:current_event) {
    create(:agenda_item, agenda: agenda, kind: "event",
      start_at: 1.hour.ago, end_at: 1.hour.from_now, name: "Ongoing Event")
  }

  before { overdue_task; completed_task; upcoming_event; current_event }

  it "kind:task narrows by enum-as-string" do
    expect(AgendaItem.query("kind:task")).to contain_exactly(overdue_task, completed_task)
  end

  it "bare 'tasks' is treated as kind:task" do
    expect(AgendaItem.query("tasks")).to contain_exactly(overdue_task, completed_task)
  end

  it "bare 'events' is treated as kind:event" do
    expect(AgendaItem.query("events")).to contain_exactly(upcoming_event, current_event)
  end

  it "kind:task + incomplete + overdue narrows to incomplete past-due tasks" do
    expect(AgendaItem.query("kind:task incomplete overdue")).to contain_exactly(overdue_task)
  end

  it "overdue excludes events (events auto-disappear when end_at passes)" do
    _past_event = create(:agenda_item, agenda: agenda, kind: "event",
      start_at: 3.days.ago, end_at: 3.days.ago + 1.hour,
      completed_at: nil, name: "Past Meeting")

    expect(AgendaItem.query("overdue")).to contain_exactly(overdue_task)
    expect(AgendaItem.query("overdue").pluck(:kind)).not_to include("event")
  end

  it "upcoming narrows to future-starting items" do
    expect(AgendaItem.query("upcoming")).to contain_exactly(upcoming_event)
  end

  it "name:overdue does a name ILIKE search" do
    expect(AgendaItem.query("name:Overdue")).to contain_exactly(overdue_task)
  end

  it "recurring narrows to items linked to a schedule" do
    sched = create(:agenda_schedule, agenda: agenda, recurrence: { "freq" => "daily" }, starts_on: Date.current)
    recurring_item = sched.agenda_items.create!(agenda: agenda, kind: "task",
      name: "From schedule", start_at: 1.day.ago)
    expect(AgendaItem.query("recurring")).to contain_exactly(recurring_item)
  end
end
