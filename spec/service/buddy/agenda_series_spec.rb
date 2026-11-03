require "rails_helper"

# `add_agenda_item` with a repeat makes an AgendaSchedule (the shared Recurrence
# vocabulary) rather than one row.
RSpec.describe Buddy::AgendaSeries do
  let(:user)     { create(:user) }
  let!(:convo)   { user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current) }
  let(:msg)      { convo.byte_messages.create!(user: user, direction: :inbound, state: :delivered, body: "ok") }
  let!(:agenda)  { Agenda.create!(user: user, name: "Mine") }
  let(:tomorrow) { 1.day.from_now.in_time_zone(user.timezone).change(hour: 8, min: 30) }

  before { allow(MonitorChannel).to receive(:broadcast_to) }

  def add(payload)
    Buddy::ProposalBuilder.create(
      user: user, byte_message: msg,
      markers: [{ tool_name: :add_agenda_item, payload: payload, span: [0, 0] }]
    )
  end

  describe "adding a repeating task" do
    # The rule hash carries the clock inside it because a BuddyReminder has no
    # column for one. AgendaSchedule does, and leaving `at` in the jsonb lands
    # every occurrence at midnight. Level 2 promises an undo, and removing the
    # schedule takes its occurrences with it.
    it "creates a series with the clock on the column, and undo takes the whole series back off", :aggregate_failures do
      result = nil
      expect { result = add(title: "Check the front flower bed", at: tomorrow.iso8601, kind: :task, repeat: "daily") }
        .to change(AgendaSchedule, :count).by(1)

      schedule = AgendaSchedule.last
      expect(schedule.name).to eq("Check the front flower bed")
      expect(schedule.recurrence["freq"]).to eq("daily")
      expect(schedule.kind).to eq("task")
      expect(schedule.duration_minutes).to be_nil
      expect(schedule.start_time.strftime("%H:%M")).to eq("08:30")
      expect(schedule.recurrence).not_to have_key("at")
      expect(schedule.recurrence).not_to have_key("starts_on")

      btn = result[:action].buttons.first
      expect(btn["status"]).to eq("executed")
      expect(btn["undoable"]).to be(true)

      Buddy::ProposalExecutor.undo!(result[:action].id, btn["id"])

      expect(AgendaSchedule.count).to eq(0)
      expect(AgendaItem.count).to eq(0)
    end

    it "takes the clock from `at` unless the spec carries its own" do
      add(title: "Flower bed", at: tomorrow.iso8601, kind: :task, repeat: "weekly:wednesday")
      expect(AgendaSchedule.last.start_time.strftime("%H:%M")).to eq("08:30")
      expect(AgendaSchedule.last.recurrence["by_day"]).to eq(["wed"])

      add(title: "Flower bed", at: tomorrow.iso8601, kind: :task, repeat: "daily:06:15")
      expect(AgendaSchedule.last.start_time.strftime("%H:%M")).to eq("06:15")
    end

    # Pinned to a clock, because AgendaSchedule::MATERIALIZE_WINDOW is 30 hours
    # and whether 08:30 tomorrow falls inside it depends on the hour of the run.
    it "materializes real occurrences off the back of it" do
      travel_to(Time.utc(2026, 8, 19, 15, 0)) do
        expect { add(title: "Flower bed", at: tomorrow.iso8601, kind: :task, repeat: "daily") }
          .to change(AgendaItem, :count)

        expect(AgendaItem.where(agenda_schedule_id: AgendaSchedule.last.id)).to exist
      end
    end

    it "honours an end date and an event's duration" do
      ends = 10.days.from_now.to_date
      add(title: "Standup", at: tomorrow.iso8601, kind: :event, duration: 45, repeat: "weekdays", until: ends.iso8601)

      expect(AgendaSchedule.last.until_on).to eq(ends)
      expect(AgendaSchedule.last.duration_minutes).to eq(45)
    end

    it "makes nothing rather than a silent one-off when the spec is unreadable" do
      expect { add(title: "Flower bed", at: tomorrow.iso8601, kind: :task, repeat: "everyish") }
        .not_to(change { [AgendaSchedule.count, AgendaItem.count] })
    end

    it "still makes a single row when nothing repeats" do
      expect { add(title: "Dentist", at: tomorrow.iso8601, kind: :event) }
        .to change(AgendaItem, :count).by(1)

      expect(AgendaSchedule.count).to eq(0)
    end
  end
end
