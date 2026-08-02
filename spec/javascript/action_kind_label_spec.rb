require "rails_helper"
require "json"
require "open3"

# The little chip above a checklist row, which is what tells someone what
# tapping the box will actually do.
#
# An agenda item is a task, an event, or a trigger, and the map used to be keyed
# on the TOOL alone — so adding a to-do to the agenda offered "Add Event", which
# is both wrong and the exact word that says whether the thing will occupy a
# span of the day. Runs the real module rather than re-deriving the mapping.
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
    it "calls a task a task" do
      expect(label_for(:add_agenda_item, { kind: "task" })).to eq("Add Task")
      expect(label_for(:edit_agenda_item, { kind: "task" })).to eq("Edit Task")
    end

    it "still calls an event an event" do
      expect(label_for(:add_agenda_item, { kind: "event" })).to eq("Add Event")
      expect(label_for(:edit_agenda_item, { kind: "event" })).to eq("Edit Event")
    end

    it "names a trigger too" do
      expect(label_for(:add_agenda_item, { kind: "trigger" })).to eq("Add Trigger")
    end

    # `kind` is optional on the tool and defaults to event, so a payload that
    # never carried one has to read the same way it always did.
    it "falls back to event when nothing says otherwise" do
      expect(label_for(:add_agenda_item)).to eq("Add Event")
    end
  end

  it "leaves the fixed labels alone" do
    expect(label_for(:complete_chore)).to eq("Complete")
    expect(label_for(:add_list_item)).to eq("Add to List")
  end

  it "gives no chip to a tool that has none" do
    expect(label_for(:some_future_tool)).to be_nil
  end
end
