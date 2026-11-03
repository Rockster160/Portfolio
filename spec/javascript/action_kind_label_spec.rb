require "rails_helper"

# The chip above a checklist row names the thing a tap acts on. Runs the real
# module rather than re-deriving the mapping.
RSpec.describe "Checklist action labels" do
  # An agenda item's kind decides its label, defaulting to an event when the
  # payload carries none; a tool the chip doesn't know gets nothing.
  cases = [
    [:add_agenda_item,  { kind: "task" },    "New Agenda Task"],
    [:edit_agenda_item, { kind: "task" },    "Edit Agenda Task"],
    [:add_agenda_item,  { kind: "event" },   "New Agenda Event"],
    [:add_agenda_item,  { kind: "trigger" }, "New Agenda Trigger"],
    [:add_agenda_item,  {},                  "New Agenda Event"],
    [:log_event,        {},                  "New Logged Event"],
    [:remove_list_item, {},                  "Remove List Item"],
    [:some_future_tool, {},                  nil],
  ]

  let(:result) {
    module_path = Rails.root.join("app/javascript/src/pages/byte/message_actions/multi_select.js")
    JsRunner.eval_module(
      <<~JS,
        import { actionKindLabel } from "#{module_path}";
        const cases = #{cases.map { |tool, payload, _| [tool, payload] }.to_json};
        console.log(JSON.stringify({
          table: cases.map(([tool, payload]) => actionKindLabel(tool, payload) ?? null),
          override: {
            off:       actionKindLabel("remove_list_item", {}, null) ?? null,
            replaced:  actionKindLabel("remove_list_item", {}, "Before Bed") ?? null,
            untouched: actionKindLabel("remove_list_item", {}) ?? null,
            unknown:   actionKindLabel("some_future_tool", {}, "Bedtime") ?? null,
          },
        }));
      JS
    )
  }

  it "labels by tool and agenda kind, and nothing for an unknown tool" do
    wrong = cases.each_with_index.filter_map { |(tool, payload, want), i|
      got = result["table"][i]
      next if got == want

      "#{tool}#{"(#{payload.to_json})" if payload.any?} → #{got.inspect}, expected #{want.inspect}"
    }

    expect(wrong).to eq([])
  end

  # A card whose rows are all the same tool turns the chip off with `null`.
  it "lets a row override the chip, including turning it off entirely" do
    expect(result["override"]).to eq(
      "off"       => nil,
      "replaced"  => "Before Bed",
      "untouched" => "Remove List Item",
      "unknown"   => "Bedtime",
    )
  end
end
