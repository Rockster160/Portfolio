require "rails_helper"

# A long drive (or an after-midnight event) means you leave the night before.
# The agenda surfaces that as a synthetic "🚙 Leave … for X" row on the earlier
# day, and tags the event's own leave label as the prior day. These lock the
# pure logic behind both — the day-crossing test and the marker shape — DOM-less,
# on the same JsRunner harness as the travel band.
RSpec.describe "the agenda leave-for marker (JS-side)" do
  let(:cases) { JsRunner.output("spec/javascript/agenda_leave_marker_runner.js", symbolize: true)[:cases] }

  it "derives the leave epoch and visibility from the travel attrs" do
    expect(cases[:derive_visible][:visible]).to be(true)
    # start (1_750_000_000) minus (5 + 12) minutes
    expect(cases[:derive_visible][:leaveEpoch]).to eq(1_750_000_000 - (17 * 60))
  end

  it "has no leave when there is no drive and no buffer" do
    expect(cases[:derive_no_band][:visible]).to be(false)
  end

  it "qualifies the day only when the leave lands earlier" do
    expect(cases[:suffix_same]).to eq("")
    expect(cases[:suffix_prev]).to eq(" (prev day)")
    expect(cases[:suffix_two]).to eq(" (2 days before)")
  end

  describe "the marker object" do
    let(:marker) { cases[:marker] }

    it "keys the row on an id that matches its own data-item-id" do
      # diffItems keys on `id` but re-finds the node by `data-item-id`; a
      # mismatch rebuilds the row every tick. This is the guard for that.
      expect(marker[:id]).to eq("leave-1058-2025-06-15")
      expect(marker[:presentation_attrs][:"item-id"]).to eq(marker[:id])
    end

    it "sits on the leave day and is inert" do
      expect(marker[:start_at]).to eq(1_750_000_000 - 86_400)
      expect(marker[:all_day]).to be(false)
      expect(marker[:editable]).to be(false)
      expect(marker[:marker]).to be(true)
    end
  end

  it "recognizes a marker by flag or by attr" do
    expect(cases[:is_marker_true]).to be(true)
    expect(cases[:is_marker_attrs]).to be(true)
    expect(cases[:is_marker_false]).to be(false)
  end
end
