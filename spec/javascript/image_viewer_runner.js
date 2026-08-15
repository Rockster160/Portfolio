// Exercises the viewer's pan/zoom arithmetic and reports as JSON for
// image_viewer_spec.rb. Same shape as the other JS runners here: the pure
// functions are imported and driven directly, no DOM.
import {
  clampPan,
  nextScale,
  clampScale,
} from "../../app/javascript/src/pages/byte/image_viewer.js";

const results = {
  // Fitted: the image is no larger than its frame, so there is no slack and
  // any drag has to resolve to nothing. This is what stops a fitted picture
  // sliding off-centre when someone swipes across it.
  fitted_cannot_drift: clampPan(200, 800, 800, 1),
  fitted_cannot_drift_negative: clampPan(-200, 800, 800, 1),

  // Zoomed 2x in an 800-wide frame: the image is 1600 across, so 400 of it
  // hangs off each side and that is exactly how far it may travel.
  zoomed_slack: clampPan(9999, 800, 800, 2),
  zoomed_slack_negative: clampPan(-9999, 800, 800, 2),
  within_slack_untouched: clampPan(120, 800, 800, 2),

  // An image narrower than its frame has slack on the other axis only.
  narrow_image_no_slack: clampPan(50, 300, 800, 1),

  // Double-tap toggles, and a fractional scale left behind by a pinch still
  // counts as zoomed-in.
  tap_from_fitted: nextScale(1),
  tap_from_zoomed: nextScale(2.5),
  tap_from_pinch_remnant: nextScale(1.4),

  ceiling: clampScale(99),
  floor: clampScale(0.2),
  passthrough: clampScale(3),
};

console.log(JSON.stringify(results));
