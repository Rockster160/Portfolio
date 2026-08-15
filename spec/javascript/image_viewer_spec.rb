require "rails_helper"
require "json"
require "open3"

# The viewer's arithmetic, driven directly. A doorbell frame in a bubble is a
# thumbnail of the one thing the notification was about, so tapping it opens it
# fitted, and from there it zooms, pans and saves.
#
# Panning is where a zoom goes wrong: let the offset run and the picture walks
# off the screen with no way back, on a surface that has no scrollbar to tell
# you where you are. So the clamp is the part worth testing, and it's the part
# kept free of the DOM in order to be testable.
RSpec.describe "Byte image viewer" do
  let(:out) {
    runner = Rails.root.join("spec/javascript/image_viewer_runner.js").to_s
    stdout, stderr, status = Open3.capture3("node", runner)
    raise "runner failed: #{stderr}" unless status.success?

    JSON.parse(stdout)
  }

  describe "panning" do
    # Fitted, the image is no bigger than its frame — there is nowhere to pan
    # to, so a swipe must resolve to nothing rather than nudging it off-centre.
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
