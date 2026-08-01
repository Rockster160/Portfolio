require "rails_helper"
require "json"
require "open3"

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
  def ordered(routines)
    script = <<~JS
      import { quickOrder } from "#{Rails.root.join("app/javascript/src/pages/byte/buddy/routine_order.js")}";
      console.log(JSON.stringify(quickOrder(#{routines.to_json}).map((r) => r.name)));
    JS
    out, err, status = Open3.capture3("node", "--input-type=module", stdin_data: script)
    raise "node failed: #{err}" unless status.success?

    JSON.parse(out)
  end

  def routine(name, position: nil, enabled: true)
    { name: name, position: position, enabled: enabled }
  end

  it "puts the starred ones first, in the order they were dragged into" do
    expect(ordered([routine("Zebra", position: 1), routine("Apple", position: 0)]))
      .to eq(["Apple", "Zebra"])
  end

  it "keeps the unstarred ones, after them and by name" do
    rows = [routine("Zebra"), routine("Starred", position: 0), routine("Apple")]

    expect(ordered(rows)).to eq(["Starred", "Apple", "Zebra"])
  end

  it "leaves out the ones switched off" do
    expect(ordered([routine("Off", enabled: false), routine("On")])).to eq(["On"])
  end

  # position 0 is a real slot, and the falsy check this replaced dropped it to
  # the bottom — so the routine most deliberately put first sorted last.
  it "treats the first slot as first, not as absent" do
    expect(ordered([routine("Unstarred"), routine("First", position: 0)]))
      .to eq(["First", "Unstarred"])
  end

  it "survives an empty list and a missing one" do
    expect(ordered([])).to eq([])
  end
end
