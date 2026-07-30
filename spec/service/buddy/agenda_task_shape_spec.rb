require "rails_helper"

# Prod 1258-1261: "add them both now" put Shower and Laundry on the agenda as
# TASKS, and both rendered as "Thu Jul 30, 2:49 PM-3:19 PM". A task has no
# duration - it sits at one moment - so the half-hour block was invented by the
# tool, not asked for.
RSpec.describe "Buddy agenda item shape" do
  let(:user) { create(:user) }
  let(:at)   { Time.current.tomorrow.change(hour: 13) }

  before { allow(AgendaTravelChainSyncWorker).to receive(:perform_async) }

  def ctx
    Buddy::ToolContext.new(user)
  end

  def run(tool_name, payload)
    tool    = Buddy::Tools[tool_name]
    confirm = tool[:confirm].call(payload, ctx)
    merged  = payload.merge(confirm[:resolved] || {})
    { result: tool[:execute].call(merged, ctx), label: tool[:label].call(merged, ctx), merged: merged }
  end

  describe "add_agenda_item" do
    it "leaves a task with no end time at all" do
      out  = run(:add_agenda_item, { title: "Shower", at: at, kind: :task })
      item = AgendaItem.find(out[:result][:agenda_item_id])

      expect(item.kind).to eq("task")
      expect(item.start_at).to be_within(1.second).of(at)
      expect(item.end_at).to be_nil
    end

    it "still gives an event its span" do
      out  = run(:add_agenda_item, { title: "Dinner", at: at, kind: :event, duration: 90 })
      item = AgendaItem.find(out[:result][:agenda_item_id])

      expect(item.end_at).to be_within(1.second).of(at + 90.minutes)
    end

    it "ignores a duration handed to a task" do
      out  = run(:add_agenda_item, { title: "Laundry", at: at, kind: :task, duration: 45 })
      item = AgendaItem.find(out[:result][:agenda_item_id])

      expect(item.end_at).to be_nil
    end

    it "shows one time on the confirm row for a task, a range for an event" do
      local = at.in_time_zone(user.timezone)
      task  = run(:add_agenda_item, { title: "Shower", at: at, kind: :task })
      event = run(:add_agenda_item, { title: "Dinner", at: at, kind: :event, duration: 90 })

      expect(task[:label][:sub]).to include(local.strftime("%-I:%M %p"))
      expect(task[:label][:sub]).not_to include("–")
      expect(event[:label][:sub]).to include("#{local.strftime("%-I:%M %p")}–#{(local + 90.minutes).strftime("%-I:%M %p")}")
    end
  end

  describe "edit_agenda_item" do
    let(:agenda) { user.agendas.order(:id).first }

    it "does not grow an end time on a task that's being retimed" do
      task = agenda.agenda_items.create!(name: "Shower", start_at: at, kind: :task, status: :confirmed)

      run(:edit_agenda_item, { item: "Shower", at: (at + 2.hours), duration: 45 })

      expect(task.reload.start_at).to be_within(1.second).of(at + 2.hours)
      expect(task.end_at).to be_nil
    end

    # end_at doesn't move on its own, so pushing an event later used to leave it
    # behind the new start and fail the end-after-start validation.
    it "carries an event's existing length along when only the start moves" do
      event = agenda.agenda_items.create!(name: "Dinner", start_at: at, end_at: at + 90.minutes, kind: :event, status: :confirmed)

      run(:edit_agenda_item, { item: "Dinner", at: (at + 3.hours) })

      expect(event.reload.start_at).to be_within(1.second).of(at + 3.hours)
      expect(event.end_at).to be_within(1.second).of(at + 3.hours + 90.minutes)
    end
  end
end
