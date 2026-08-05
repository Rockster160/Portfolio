require "rails_helper"

# `add_agenda_item` could only ever make ONE row, so "check the front flower bed
# daily" had nowhere to go - it became a custom watch on a list that didn't
# exist, and never fired. AgendaSchedule already spoke the shared Recurrence
# vocabulary; nothing reached it.
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
    it "creates a series rather than a single row" do
      expect { add(title: "Check the front flower bed", at: tomorrow.iso8601, kind: :task, repeat: "daily") }
        .to change(AgendaSchedule, :count).by(1)

      schedule = AgendaSchedule.last
      expect(schedule.name).to eq("Check the front flower bed")
      expect(schedule.recurrence["freq"]).to eq("daily")
      expect(schedule.kind).to eq("task")
    end

    # The rule hash carries the clock inside it because a BuddyReminder has no
    # column for one. AgendaSchedule does, and leaving `at` in the jsonb lands
    # every occurrence at midnight.
    it "hoists the time of day out of the rule and onto the column" do
      add(title: "Flower bed", at: tomorrow.iso8601, kind: :task, repeat: "daily")

      schedule = AgendaSchedule.last
      expect(schedule.start_time.strftime("%H:%M")).to eq("08:30")
      expect(schedule.recurrence).not_to have_key("at")
      expect(schedule.recurrence).not_to have_key("starts_on")
    end

    it "takes the clock from `at` when the spec doesn't carry one" do
      add(title: "Flower bed", at: tomorrow.iso8601, kind: :task, repeat: "weekly:wednesday")

      schedule = AgendaSchedule.last
      expect(schedule.start_time.strftime("%H:%M")).to eq("08:30")
      expect(schedule.recurrence["by_day"]).to eq(["wed"])
    end

    it "lets the spec's own clock win when it has one" do
      add(title: "Flower bed", at: tomorrow.iso8601, kind: :task, repeat: "daily:06:15")

      expect(AgendaSchedule.last.start_time.strftime("%H:%M")).to eq("06:15")
    end

    it "materializes real occurrences off the back of it" do
      expect { add(title: "Flower bed", at: tomorrow.iso8601, kind: :task, repeat: "daily") }
        .to change(AgendaItem, :count)

      expect(AgendaItem.where(agenda_schedule_id: AgendaSchedule.last.id)).to exist
    end

    it "honours an end date" do
      ends = 10.days.from_now.to_date
      add(title: "Flower bed", at: tomorrow.iso8601, kind: :task, repeat: "daily", until: ends.iso8601)

      expect(AgendaSchedule.last.until_on).to eq(ends)
    end

    it "carries an event's duration, and leaves a task without one" do
      add(title: "Standup", at: tomorrow.iso8601, kind: :event, duration: 45, repeat: "weekdays")
      expect(AgendaSchedule.last.duration_minutes).to eq(45)

      add(title: "Flower bed", at: tomorrow.iso8601, kind: :task, repeat: "daily")
      expect(AgendaSchedule.last.duration_minutes).to be_nil
    end

    it "says so rather than making a silent one-off when the spec is unreadable" do
      expect { add(title: "Flower bed", at: tomorrow.iso8601, kind: :task, repeat: "everyish") }
        .not_to(change(AgendaSchedule, :count))
    end

    it "still makes a single row when nothing repeats" do
      expect { add(title: "Dentist", at: tomorrow.iso8601, kind: :event) }
        .to change(AgendaItem, :count).by(1)

      expect(AgendaSchedule.count).to eq(0)
    end
  end

  # Level 2 promises an undo, and the row is a lie without one. Removing the
  # schedule takes its occurrences with it (`dependent: :destroy`).
  describe "undoing one" do
    it "takes the whole series back off" do
      result = add(title: "Flower bed", at: tomorrow.iso8601, kind: :task, repeat: "daily")
      btn    = result[:action].buttons.first

      expect(btn["status"]).to eq("executed")
      expect(btn["undoable"]).to be(true)

      Buddy::ProposalExecutor.undo!(result[:action].id, btn["id"])

      expect(AgendaSchedule.count).to eq(0)
      expect(AgendaItem.count).to eq(0)
    end

    it "is a model the Reverter knows how to walk back" do
      expect(Buddy::Reverter::MODELS).to include("AgendaSchedule")
    end
  end

  it "says on the receipt that it repeats, so it's not mistaken for a one-off" do
    result = add(title: "Flower bed", at: tomorrow.iso8601, kind: :task, repeat: "daily")

    expect(result[:action].buttons.first["receipt"].to_s).to match(/Flower bed/).and match(/day/i)
  end

  it "marks the row as repeating so the person sees it before it runs away" do
    result = add(title: "Flower bed", at: tomorrow.iso8601, kind: :task, repeat: "daily")

    expect(result[:action].buttons.first["sublabel"].to_s).to include("🔁")
  end
end
