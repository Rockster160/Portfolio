// Exercises the viewer's pan/zoom arithmetic and reports as JSON for
// image_viewer_spec.rb. Same shape as the other JS runners here: the pure
// functions are imported and driven directly, no DOM.
import {
  clampPan,
  nextScale,
  clampScale,
  focalPan,
} from "../../app/javascript/src/pages/byte/image_viewer.js";

// Where the point that was under the fingers ends up once the zoom lands —
// which is the invariant the whole thing exists for, so it's what the spec
// asserts rather than the offset in isolation.
//
// The picture's middle moves by however much the pan changed, and the point
// sits `focal - center` from that middle, magnified by the ratio.
function focalAfter(focal, center, offset, from, to) {
  const next = focalPan(offset, focal, center, from, to);
  const nextCenter = center - offset + next;
  return nextCenter + (focal - center) * (to / from);
}

// The same zoom with no anchoring at all — what it did before, and what "zooms
// forward generically and then you pan to where you wanted" measures as.
function unanchored(focal, center, from, to) {
  return center + (focal - center) * (to / from);
}

const results = {
  // Fitted: the image is no larger than its frame, so there is no slack and
  // any drag has to resolve to nothing. This is what stops a fitted picture
  // sliding off-center when someone swipes across it.
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

  // Anchored zoom. An 800-wide frame, so the picture's middle sits at 400;
  // pinching at 600 is pinching 200px right of the middle.
  //
  // The point pinched has to still be at 600 afterwards, at every scale and in
  // both directions, including when the picture is already offset from a
  // previous pan.
  focal_in_stays_put: focalAfter(600, 400, 0, 1, 2),
  focal_out_stays_put: focalAfter(600, 400, 0, 4, 2),
  focal_already_panned_stays_put: focalAfter(600, 400, 50, 2, 4),
  focal_top_left_corner_stays_put: focalAfter(90, 400, -30, 1.5, 3),

  // Pinching the middle is the one case where anchoring has nothing to do.
  focal_on_center_is_a_no_op: focalPan(75, 400, 400, 1, 3),
  // Two fingers moving together without spreading: no scale change, so the
  // anchor correction contributes nothing and the drag is the whole movement.
  focal_no_zoom_is_a_no_op: focalPan(75, 600, 400, 2, 2),
  // Degenerate, rather than NaN-ing the transform.
  focal_zero_scale_guard: focalPan(75, 600, 400, 0, 2),

  // What it did before: the same pinch, unanchored, leaves the point 200px
  // away from the fingers that asked for it.
  unanchored_drift: unanchored(600, 400, 1, 2) - 600,
};

console.log(JSON.stringify(results));
