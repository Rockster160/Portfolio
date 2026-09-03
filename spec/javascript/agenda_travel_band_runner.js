// Locks the one rule that decides whether an agenda row draws its travel
// band: the "min early" setting is on EVERY item — 5 unless they said
// otherwise, so an address added later already has one — and it only means
// something once there is somewhere to go.
//
// Rocco, 3 Sep 2026: *"I'd prefer it to always be 5 but just have it ignored
// if there is no location. That way if we ever edit something to HAVE a
// location, we don't have to also worry about remembering to set the early
// arrive time."* So the number stays on the row and the BAND is what's gated.

const path = require("path");

const Renderer = require(path.resolve(
  __dirname, "..", "..", "app", "javascript", "src", "agenda_renderer", "item_renderer.js",
));

const band = (attrs) => Renderer.travelBand(attrs);

const cases = {
  // The setting is there, and there is nowhere to be.
  no_location: band({ "arrive-early-minutes": 5, "travel-minutes": 0, location: "" }),
  // Same row once somebody types the address in. Nothing was re-entered.
  location_added: band({ "arrive-early-minutes": 5, "travel-minutes": 0, location: "Lucky Ones Coffee" }),
  // A Zoom link is not a place you leave for — the same test the location
  // chrome uses.
  url_location: band({ "arrive-early-minutes": 5, "travel-minutes": 0, location: "https://meet.google.com/bzy-xcsh-bkj" }),
  // A drive stands on its own; the gate is only ever about the early buffer.
  drive_no_location: band({ "arrive-early-minutes": 5, "travel-minutes": 12, location: "" }),
  both: band({ "arrive-early-minutes": 10, "travel-minutes": 12, location: "Rowley's Red Barn" }),
  // Nought means nought, place or no place.
  explicit_zero: band({ "arrive-early-minutes": 0, "travel-minutes": 0, location: "Lucky Ones Coffee" }),
};

console.log(JSON.stringify({ cases }));
