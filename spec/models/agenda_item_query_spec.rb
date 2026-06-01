require "rails_helper"

RSpec.describe "AgendaItem.query — is:<state> markers" do
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

  it "is:task is equivalent to kind:task" do
    expect(AgendaItem.query("is:task")).to contain_exactly(overdue_task, completed_task)
  end

  it "is:event narrows by event kind" do
    expect(AgendaItem.query("is:event")).to contain_exactly(upcoming_event, current_event)
  end

  it "combines is: filters: kind:task is:incomplete is:overdue narrows to overdue incomplete tasks" do
    expect(AgendaItem.query("kind:task is:incomplete is:overdue")).to contain_exactly(overdue_task)
  end

  it "is:overdue excludes events (events auto-disappear when end_at passes)" do
    _past_event = create(:agenda_item, agenda: agenda, kind: "event",
      start_at: 3.days.ago, end_at: 3.days.ago + 1.hour,
      completed_at: nil, name: "Past Meeting")

    expect(AgendaItem.query("is:overdue")).to contain_exactly(overdue_task)
    expect(AgendaItem.query("is:overdue").pluck(:kind)).not_to include("event")
  end

  it "is:upcoming narrows to future-starting items" do
    expect(AgendaItem.query("is:upcoming")).to contain_exactly(upcoming_event)
  end

  it "name:Overdue does a name ILIKE search" do
    expect(AgendaItem.query("name:Overdue")).to contain_exactly(overdue_task)
  end

  it "is:recurring narrows to items linked to a schedule" do
    sched = create(:agenda_schedule, agenda: agenda, recurrence: { "freq" => "daily" }, starts_on: Date.current)
    recurring_item = sched.agenda_items.create!(agenda: agenda, kind: "task",
      name: "From schedule", start_at: 1.day.ago)
    expect(AgendaItem.query("is:recurring")).to contain_exactly(recurring_item)
  end

  it "bare 'upcoming' is treated as free-text, NOT a state filter" do
    upcoming_named = create(:agenda_item, agenda: agenda, kind: "task",
      name: "Upcoming review", start_at: 5.days.from_now, completed_at: nil)
    results = AgendaItem.query("upcoming")
    expect(results).to include(upcoming_named)
    expect(results).not_to include(overdue_task)
    expect(results).not_to include(upcoming_event)
  end

  it "bare 'event' is treated as free-text, NOT a kind filter" do
    name_match = create(:agenda_item, agenda: agenda, kind: "task",
      name: "Plan the event", start_at: 1.day.from_now, completed_at: nil)
    # Free-text matches the literal word; kind:event filter would have
    # excluded this task. We expect the task TO appear and the existing
    # bare kind: "event" rows (Future Event, Ongoing Event) to also appear
    # because both contain "event" in the name.
    results = AgendaItem.query("event")
    expect(results).to include(name_match)
    # Items whose name does NOT contain "event" are excluded.
    expect(results).not_to include(completed_task) # "Done Task" — no "event"
  end
end
