require "rails_helper"
require "json"
require "open3"

# The little chip above a checklist row, which is what tells someone what
# tapping the box will actually do.
#
# It names the THING and where it lives rather than the verb that runs: "Add
# Task" was the tool's name for itself, and "New Agenda Task" is the answer to
# the question somebody reading a confirmation is asking. Runs the real module
# rather than re-deriving the mapping.
RSpec.describe "Checklist action labels" do
  def label_for(tool, payload={})
    script = <<~JS
      import { actionKindLabel } from "#{Rails.root.join("app/javascript/src/pages/byte/message_actions/multi_select.js")}";
      console.log(JSON.stringify(actionKindLabel(#{tool.to_s.inspect}, #{payload.to_json})));
    JS
    out, err, status = Open3.capture3("node", "--input-type=module", stdin_data: script)
    raise "node failed: #{err}" unless status.success?

    JSON.parse(out)
  end

  describe "an agenda item" do
    # An agenda item is a task, an event, or a trigger, and they are not the
    # same thing to whoever's reading — a to-do called an "Event" is wrong, and
    # it's the word that says whether it will occupy a span of the day.
    it "calls a task a task, and says which list it lands on" do
      expect(label_for(:add_agenda_item, { kind: "task" })).to eq("New Agenda Task")
      expect(label_for(:edit_agenda_item, { kind: "task" })).to eq("Edit Agenda Task")
    end

    it "still calls an event an event" do
      expect(label_for(:add_agenda_item, { kind: "event" })).to eq("New Agenda Event")
      expect(label_for(:edit_agenda_item, { kind: "event" })).to eq("Edit Agenda Event")
    end

    it "names a trigger too" do
      expect(label_for(:add_agenda_item, { kind: "trigger" })).to eq("New Agenda Trigger")
    end

    # `kind` is optional on the tool and defaults to event, so a payload that
    # never carried one has to read the same way it always did.
    it "falls back to event when nothing says otherwise" do
      expect(label_for(:add_agenda_item)).to eq("New Agenda Event")
    end
  end

  # The qualifier is doing real work here: an agenda Event and a logged event
  # are different things that used to read as "Add Event" and "Log".
  it "keeps a logged event apart from a calendar one" do
    expect(label_for(:log_event)).to eq("New Logged Event")
    expect(label_for(:edit_event)).to eq("Edit Logged Event")
    expect(label_for(:delete_event)).to eq("Delete Logged Event")
  end

  it "names what a bare verb used to leave implied" do
    expect(label_for(:complete_chore)).to eq("Complete Chore")
    expect(label_for(:schedule_reminder)).to eq("New Reminder")
    expect(label_for(:create_chore)).to eq("New Chore")
    expect(label_for(:add_list_item)).to eq("New List Item")
  end

  # A destructive row with no chip is a bare title over a checkbox, which is the
  # least legible one of these can be: "Forget kettle" doesn't say whether
  # ticking the box teaches the household that word or drops it.
  it "names every row that takes something away" do
    expect(label_for(:cancel_reminder)).to eq("Cancel Reminder")
    expect(label_for(:cancel_timer)).to eq("Stop Timer")
    expect(label_for(:forget_routine)).to eq("Delete Routine")
    expect(label_for(:forget_term)).to eq("Delete Glossary Term")
    expect(label_for(:unlink_records)).to eq("Unlink Records")
    expect(label_for(:remove_list_item)).to eq("Remove List Item")
    expect(label_for(:undo_chore_completion)).to eq("Undo Chore")
  end

  it "gives no chip to a tool that has none" do
    expect(label_for(:some_future_tool)).to be_nil
  end
end
