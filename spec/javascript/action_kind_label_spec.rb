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
  # What the function IS: one table, tool in, chip out. It was asserted eight
  # examples at a time, each spawning a node process per lookup — twenty-three
  # of them to read one table — and the whole table in one pass says the same
  # thing and names the row that moved.
  cases = [
    # An agenda item is a task, an event, or a trigger, and they are not the
    # same thing to whoever's reading — a to-do called an "Event" is wrong, and
    # it's the word that says whether it will occupy a span of the day.
    [:add_agenda_item,        { kind: "task" },    "New Agenda Task"],
    [:edit_agenda_item,       { kind: "task" },    "Edit Agenda Task"],
    [:add_agenda_item,        { kind: "event" },   "New Agenda Event"],
    [:edit_agenda_item,       { kind: "event" },   "Edit Agenda Event"],
    [:add_agenda_item,        { kind: "trigger" }, "New Agenda Trigger"],
    # `kind` is optional on the tool and defaults to event, so a payload that
    # never carried one has to read the same way it always did.
    [:add_agenda_item,        {},                  "New Agenda Event"],

    # The qualifier is doing real work here: an agenda Event and a logged event
    # are different things that used to read as "Add Event" and "Log".
    [:log_event,              {},                  "New Logged Event"],
    [:edit_event,             {},                  "Edit Logged Event"],
    [:delete_event,           {},                  "Delete Logged Event"],

    # What a bare verb used to leave implied.
    [:complete_chore,         {},                  "Complete Chore"],
    [:schedule_reminder,      {},                  "New Reminder"],
    [:create_chore,           {},                  "New Chore"],
    [:add_list_item,          {},                  "New List Item"],

    # A destructive row with no chip is a bare title over a checkbox, which is
    # the least legible one of these can be: "Forget kettle" doesn't say whether
    # ticking the box teaches the household that word or drops it.
    [:cancel_reminder,        {},                  "Cancel Reminder"],
    [:cancel_timer,           {},                  "Stop Timer"],
    [:forget_routine,         {},                  "Delete Routine"],
    [:forget_term,            {},                  "Delete Glossary Term"],
    [:unlink_records,         {},                  "Unlink Records"],
    [:remove_list_item,       {},                  "Remove List Item"],
    [:undo_chore_completion,  {},                  "Undo Chore"],

    # And nothing for a tool the chip has never heard of.
    [:some_future_tool,       {},                  nil],
  ]

  it "names the thing and where it lives, for every row that gets a chip" do
    module_path = Rails.root.join("app/javascript/src/pages/byte/message_actions/multi_select.js")
    script = <<~JS
      import { actionKindLabel } from "#{module_path}";
      const cases = #{cases.map { |tool, payload, _| [tool, payload] }.to_json};
      console.log(JSON.stringify(cases.map(([tool, payload]) => actionKindLabel(tool, payload) ?? null)));
    JS
    out, err, status = Open3.capture3("node", "--input-type=module", stdin_data: script)
    raise "node failed: #{err}" unless status.success?

    got = JSON.parse(out)
    # Reported as a list of the rows that moved rather than as two whole
    # tables: a diff of twenty-two entries is elided in the middle, which is
    # where the wrong one always is.
    wrong = cases.each_with_index.filter_map { |(tool, payload, want), i|
      next if got[i] == want

      "#{tool}#{"(#{payload.to_json})" if payload.any?} → #{got[i].inspect}, expected #{want.inspect}"
    }

    expect(wrong).to eq([])
  end
end
