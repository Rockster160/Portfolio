require "rails_helper"

# The viewer's arithmetic, driven directly. A doorbell frame in a bubble is a
# thumbnail of the one thing the notification was about, so tapping it opens it
# fitted, and from there it zooms, pans and saves.
#
# Panning is where a zoom goes wrong: let the offset run and the picture walks
# off the screen with no way back, on a surface that has no scrollbar to tell
# you where you are. So the clamp is the part worth testing, and it's the part
# kept free of the DOM in order to be testable.
RSpec.describe "Byte image viewer" do
  let(:out) { JsRunner.output("spec/javascript/image_viewer_runner.js") }

  describe "panning" do
    # Fitted, the image is no bigger than its frame — there is nowhere to pan
    # to, so a swipe must resolve to nothing rather than nudging it off-center.
    it "does not let a fitted image drift" do
      expect(out["fitted_cannot_drift"]).to eq(0)
      expect(out["fitted_cannot_drift_negative"]).to eq(0)
    end

    # At 2x in an 800-wide frame the image is 1600 across, so exactly 400 hangs
    # off each side and that is the whole travel.
    it "stops at the picture's own edge" do
      expect(out["zoomed_slack"]).to eq(400)
      expect(out["zoomed_slack_negative"]).to eq(-400)
    end

    it "leaves a drag that's within bounds alone" do
      expect(out["within_slack_untouched"]).to eq(120)
    end

    it "gives no travel on an axis where the image is smaller than the frame" do
      expect(out["narrow_image_no_slack"]).to eq(0)
    end
  end

  describe "double-tap" do
    it "zooms in from fitted" do
      expect(out["tap_from_fitted"]).to be > 1
    end

    it "goes all the way back out when zoomed" do
      expect(out["tap_from_zoomed"]).to eq(1)
    end

    # Pinch leaves fractional scales behind, and a tap after one should still
    # reset rather than zooming further in.
    it "treats any zoom at all as zoomed" do
      expect(out["tap_from_pinch_remnant"]).to eq(1)
    end
  end

  # A zoom anchored on the middle of the picture walks whatever you were
  # pinching further away from your fingers, so magnifying a face in the corner
  # meant magnifying it and then dragging it back into view by hand — most of
  # the work the gesture was there to save.
  describe "anchored zoom" do
    # An 800-wide frame: the picture's middle sits at 400, and 600 is a pinch
    # 200px right of it. That spot has to still be at 600 afterwards.
    it "leaves the point being pinched exactly where it was" do
      expect(out["focal_in_stays_put"]).to be_within(0.001).of(600)
    end

    it "does the same on the way back out" do
      expect(out["focal_out_stays_put"]).to be_within(0.001).of(600)
    end

    # The picture is usually already offset by an earlier pan when a second
    # pinch starts, and that offset is part of where the middle now sits.
    it "holds when the picture has already been panned" do
      expect(out["focal_already_panned_stays_put"]).to be_within(0.001).of(600)
    end

    it "holds on the far side of the middle too" do
      expect(out["focal_top_left_corner_stays_put"]).to be_within(0.001).of(90)
    end

    it "has nothing to correct when the middle itself is pinched" do
      expect(out["focal_on_center_is_a_no_op"]).to eq(75)
    end

    # Two fingers travelling together without spreading: the pan is the whole
    # movement, and the anchor must not add to it.
    it "contributes nothing when the scale doesn't change" do
      expect(out["focal_no_zoom_is_a_no_op"]).to eq(75)
    end

    it "returns the offset untouched rather than NaN-ing the transform" do
      expect(out["focal_zero_scale_guard"]).to eq(75)
    end

    # The bug itself, measured.
    it "is what a center-anchored zoom got wrong" do
      expect(out["unanchored_drift"]).to eq(200)
    end
  end

  describe "scale bounds" do
    it "caps how far in it goes" do
      expect(out["ceiling"]).to eq(6)
    end

    # Below fit there'd be dead space around a picture that already fits.
    it "never goes below fit" do
      expect(out["floor"]).to eq(1)
    end

    it "leaves an ordinary scale alone" do
      expect(out["passthrough"]).to eq(3)
    end
  end
end
