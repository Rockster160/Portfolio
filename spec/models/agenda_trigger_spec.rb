require "rails_helper"

RSpec.describe "AgendaItem trigger kind" do
  let(:user) { create(:user) }
  let(:agenda) { create(:agenda, user: user) }

  describe "kind enum" do
    it "includes :trigger" do
      expect(AgendaItem.kinds).to include("trigger" => 2)
      expect(AgendaSchedule.kinds).to include("trigger" => 2)
    end
  end

  describe "Execution.auth_types" do
    it "includes :agenda for items fired by agenda triggers" do
      expect(Execution.auth_types["agenda"]).to eq(10)
    end
  end

  describe "AgendaItem#parsed_trigger" do
    it "returns [scope, data] with agenda_item tieback for a bare expression" do
      item = create(:agenda_item, agenda: agenda, kind: "trigger",
        name: "Morning routine", trigger_expression: "goodMorning",
        start_at: 1.hour.from_now)
      scope, data = item.parsed_trigger
      expect(scope).to eq("goodMorning")
      expect(data[:agenda_item]).to include(id: item.id, agenda_id: agenda.id, name: "Morning routine")
    end

    it "parses nested scope:key:value into data" do
      item = create(:agenda_item, agenda: agenda, kind: "trigger",
        name: "Quiet alert", trigger_expression: "notify:tone:soft",
        start_at: 1.hour.from_now)
      scope, data = item.parsed_trigger
      expect(scope).to eq("notify")
      expect(data[:tone]).to eq("soft")
      expect(data[:agenda_item]).to be_present
    end

    it "supports quoted segments with spaces" do
      item = create(:agenda_item, agenda: agenda, kind: "trigger",
        name: "Spaced key", trigger_expression: 'alert:"my key":value',
        start_at: 1.hour.from_now)
      scope, data = item.parsed_trigger
      expect(scope).to eq("alert")
      expect(data[:"my key"]).to eq("value")
    end

    it "returns [nil, {}] for non-trigger kinds" do
      item = create(:agenda_item, agenda: agenda, kind: "task", name: "Walk dog",
        start_at: 1.hour.from_now)
      expect(item.parsed_trigger).to eq([nil, {}])
    end

    it "returns [nil, {}] for trigger items with blank trigger_expression" do
      item = create(:agenda_item, agenda: agenda, kind: "trigger",
        name: "Empty trigger", trigger_expression: nil,
        start_at: 1.hour.from_now)
      expect(item.parsed_trigger).to eq([nil, {}])
    end

    it "non-event triggers have nil end_at when generated from a schedule" do
      sched = create(:agenda_schedule, agenda: agenda, kind: "trigger",
        name: "Morning ping", trigger_expression: "ping",
        recurrence: { "freq" => "daily" }, starts_on: Date.current)
      # 7 days are auto-materialized for trigger schedules; query beyond the
      # window to exercise the phantom path.
      phantom = sched.phantom_for(Date.current + 30)
      expect(phantom.end_at).to be_nil
      expect(phantom.trigger_expression).to eq("ping")
    end
  end

  describe "AgendaSchedule#materialize_upcoming_triggers!" do
    it "materializes only the occurrences that fall inside the 10-hour forward window" do
      sched = nil
      start_time = 1.hour.from_now.strftime("%H:%M")
      expect {
        sched = create(:agenda_schedule, agenda: agenda, kind: "trigger",
          name: "Morning ping", trigger_expression: "morning_ping",
          start_time: start_time,
          recurrence: { "freq" => "daily" }, starts_on: Date.current)
      }.to change { AgendaItem.where(kind: :trigger).count }.by(1)
      expect(sched.agenda_items.where(kind: :trigger).count).to eq(1)
      expect(sched.agenda_items.pluck(:trigger_expression).uniq).to eq(["morning_ping"])
    end

    it "does NOT pre-materialize occurrences beyond the 10-hour window" do
      far_off = (Time.current + 12.hours).strftime("%H:%M")
      expect {
        create(:agenda_schedule, agenda: agenda, kind: "trigger",
          name: "Late ping", trigger_expression: "late_ping",
          start_time: far_off,
          recurrence: { "freq" => "daily" }, starts_on: Date.current)
      }.not_to change { AgendaItem.where(kind: :trigger).count }
    end

    it "non-trigger schedules do NOT auto-materialize" do
      expect {
        create(:agenda_schedule, agenda: agenda, kind: "task",
          recurrence: { "freq" => "daily" }, starts_on: Date.current)
      }.not_to change(AgendaItem, :count)
    end
  end

  describe "FireDueAgendaTriggersWorker" do
    it "fires due trigger items and stamps fired_at WITHOUT touching completed_at" do
      item = create(:agenda_item, agenda: agenda, kind: "trigger",
        name: "Ping reminder", trigger_expression: "ping",
        start_at: 5.minutes.ago, completed_at: nil)
      expect(::Jil).to receive(:trigger).with(user, "ping", hash_including(agenda_item: include(id: item.id)),
        auth: :agenda, auth_id: item.id)
      FireDueAgendaTriggersWorker.new.perform
      expect(item.reload.fired_at).to be_present
      expect(item.completed_at).to be_nil
    end

    it "doesn't refire a trigger that already has fired_at set" do
      item = create(:agenda_item, agenda: agenda, kind: "trigger",
        name: "Ping", trigger_expression: "ping",
        start_at: 5.minutes.ago, fired_at: 4.minutes.ago)
      expect(::Jil).not_to receive(:trigger)
      FireDueAgendaTriggersWorker.new.perform
    end

    it "ignores triggers in the future" do
      item = create(:agenda_item, agenda: agenda, kind: "trigger",
        name: "Ping", trigger_expression: "ping",
        start_at: 1.hour.from_now, completed_at: nil)
      expect(::Jil).not_to receive(:trigger)
      FireDueAgendaTriggersWorker.new.perform
      expect(item.reload.completed_at).to be_nil
    end

    it "ignores already-completed triggers" do
      item = create(:agenda_item, agenda: agenda, kind: "trigger",
        name: "Ping", trigger_expression: "ping",
        start_at: 5.minutes.ago, completed_at: 1.minute.ago)
      expect(::Jil).not_to receive(:trigger)
      FireDueAgendaTriggersWorker.new.perform
    end

    it "routes `command:` triggers through Jarvis instead of Jil" do
      item = create(:agenda_item, agenda: agenda, kind: "trigger",
        name: "Wash Dishes Reminder",
        trigger_expression: 'command:"Remind me to wash dishes"',
        start_at: 5.minutes.ago, completed_at: nil)
      expect(::Jarvis).to receive(:command).with(user, "Remind me to wash dishes")
      expect(::Jil).not_to receive(:trigger)
      FireDueAgendaTriggersWorker.new.perform
      expect(item.reload.fired_at).to be_present
      expect(item.completed_at).to be_nil
    end

    it "handles `command:words` without quotes when there are no extra colons" do
      item = create(:agenda_item, agenda: agenda, kind: "trigger",
        name: "Reminder",
        trigger_expression: "command:Remind me to take out trash",
        start_at: 5.minutes.ago, completed_at: nil)
      expect(::Jarvis).to receive(:command).with(user, "Remind me to take out trash")
      FireDueAgendaTriggersWorker.new.perform
    end

    it "preserves nested quotes inside the command words" do
      item = create(:agenda_item, agenda: agenda, kind: "trigger",
        name: "Plants Reminder",
        trigger_expression: 'command:Remind me to "add water to plants"',
        start_at: 5.minutes.ago, completed_at: nil)
      expect(::Jarvis).to receive(:command).with(user, 'Remind me to "add water to plants"')
      FireDueAgendaTriggersWorker.new.perform
    end
  end
end
