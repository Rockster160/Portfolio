require "rails_helper"

# What the Quick popover and the wall tablet list, and in what order.
#
# Starring used to be the GATE rather than a promotion, which made saving a
# routine two steps: you'd save one, open Quick to run it, and find an empty
# panel telling you to go star it in a drawer you weren't looking at.
#
# The client rebuilds this list from /buddy/routines while the server renders
# the same one into the kiosk shell, so the two orderings have to agree —
# BuddyRoutine.for_quick is the other half of this, and its spec is the mirror
# of this one. Runs the real module rather than re-deriving the rule.
RSpec.describe "Quick routine ordering" do
  # Every fixture at once. Each example below asks a different question, but
  # they all needed the same module loaded to answer it, and a node process per
  # example to load it was the whole cost of this file.
  fixtures = {
    starred_first:    ["quickOrder", [{ name: "Zebra", position: 1 }, { name: "Apple", position: 0 }]],
    unstarred_after:  ["quickOrder", [{ name: "Zebra" }, { name: "Starred", position: 0 }, { name: "Apple" }]],
    switched_off:     ["quickOrder", [{ name: "Off", enabled: false }, { name: "On" }]],
    first_slot:       ["quickOrder", [{ name: "Unstarred" }, { name: "First", position: 0 }]],
    empty:            ["quickOrder", []],
    wall_starred:     ["kioskOrder", [{ name: "Zebra", position: 1 }, { name: "Unstarred" }, { name: "Apple", position: 0 }]],
    wall_switched_off: ["kioskOrder", [{ name: "Off", position: 0, enabled: false }, { name: "On", position: 1 }]],
    wall_none_starred: ["kioskOrder", [{ name: "Saved" }, { name: "Also saved" }]],
  }

  let(:ordered) {
    module_path = Rails.root.join("app/javascript/src/pages/byte/buddy/routine_order.js")
    script = <<~JS
      import { quickOrder, kioskOrder } from "#{module_path}";
      const fns = { quickOrder, kioskOrder };
      const cases = #{fixtures.transform_keys(&:to_s).to_json};
      const out = {};
      for (const [name, [fn, rows]] of Object.entries(cases)) {
        out[name] = fns[fn](rows.map((r) => ({ position: null, enabled: true, ...r }))).map((r) => r.name);
      }
      console.log(JSON.stringify(out));
    JS
    JsRunner.eval_module(script, symbolize: true)
  }

  it "puts the starred ones first, in the order they were dragged into" do
    expect(ordered[:starred_first]).to eq(%w[Apple Zebra])
  end

  it "keeps the unstarred ones, after them and by name" do
    expect(ordered[:unstarred_after]).to eq(%w[Starred Apple Zebra])
  end

  it "leaves out the ones switched off" do
    expect(ordered[:switched_off]).to eq(["On"])
  end

  # position 0 is a real slot, and the falsy check this replaced dropped it to
  # the bottom — so the routine most deliberately put first sorted last.
  it "treats the first slot as first, not as absent" do
    expect(ordered[:first_slot]).to eq(%w[First Unstarred])
  end

  it "survives an empty list" do
    expect(ordered[:empty]).to eq([])
  end

  # The wall is the one place the star is a GATE rather than a promotion, and
  # it's about space: a fixed pad has room for a handful of big targets, so
  # carrying every routine there buries the three you walk up and press.
  # BuddyRoutine.for_kiosk is the server half of this and has to agree.
  describe "the wall tablet" do
    it "takes only the starred ones, in their dragged order" do
      expect(ordered[:wall_starred]).to eq(%w[Apple Zebra])
    end

    it "still drops a starred one that's switched off" do
      expect(ordered[:wall_switched_off]).to eq(["On"])
    end

    it "comes back empty when they have routines but none starred" do
      expect(ordered[:wall_none_starred]).to eq([])
    end
  end
end
