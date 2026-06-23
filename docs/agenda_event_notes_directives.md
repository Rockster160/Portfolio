# Agenda Event Notes Directives

Travel-time directives recognized in the **notes** field of an `AgendaItem`
(event). Parsed by `AgendaTravelChain::OverrideParser` and applied by
`AgendaTravelChain::Service` whenever the chain worker recomputes a day.

Each directive must sit at the **start of a line** (case-insensitive).
Any other prose in the notes is ignored. Quoted segments preserve commas
inside the value: `"3rd, St"` stays one entry.

## Directive Quick Reference

| Token | Shape | Effect |
|-------|-------|--------|
| `nonav` | bool flag | Treats this event as if it had no location — no travel band, no chain participation. |
| `notme` | bool flag | Mark the event as "not me driving"; cars / trip-build side effects fire silently. |
| `before:A,B,"3rd St"` | comma list | Waypoints inserted on the **incoming** leg; the first entry becomes the drive's destination instead of the event's location. |
| `after:A,B,"3rd St"` | comma list | Waypoints on the **outgoing** leg; the last entry becomes the chain's outgoing endpoint instead of the event's location. |
| `from:123 Main St` | single value | Explicit **incoming origin** (overrides Home / chained predecessor). Also breaks the inbound chain — the event is declared to start from somewhere other than the previous event. |
| `to:Greens Lake Campground` | single value | Explicit **outgoing destination**. Adds a post-event travel band AFTER the event (mirror of the incoming band) and acts as the outgoing endpoint for chain detection with the next event. |

## How the Two Legs Interact

The chain worker computes up to two drive legs per event:

1. **Incoming leg** — where you're coming from → where the event starts.
   - Origin: `from:` override → chained predecessor's outgoing endpoint → Home.
   - Destination: first `before:` waypoint → event's `location`.
2. **Post-event leg** — where the event ends → where you're going next.
   - Only computed when `to:` is set.
   - Origin: event's `location`.
   - Destination: `to:` value (with any `after:` waypoints implicit along the way).

Both legs short-circuit to **0 minutes** when origin and destination are
the same place (case-insensitive, whitespace-tolerant) — so an event at
"Home" with `from:Home` doesn't burn a Distance Matrix call computing a
zero-meter route.

## Chain Detection

The worker links two consecutive events (`A → B`) when the gap between
them is too tight to fit a natural reset between the two:

- Without `to:` on A — the "reset" is Home. Chain if A→Home→B doesn't fit.
- With `to:` on A — the "reset" is the `to:` location. Chain if
  A→`to:`→B doesn't fit. A is treated as committed to reaching the
  `to:` destination regardless.

`from:` on B always breaks the inbound chain (B is asserting its own
origin, independent of A).

## Examples

### Simple post-event drive

```
to:Greens Lake Campground
```

Use on an event at Home named "Leave". After the event ends, the
calendar shows a post-travel band with `🚗 3h 35m →6:35p`. No incoming
band (you're already at Home when the event starts).

### Already-on-site (zero incoming)

```
from:Greens Lake Campground
to:Home
```

Use on an event at the campground named "Return Home". Incoming is
short-circuited to 0 (`from:` matches the event's location). Post-event
band shows the drive back to Home.

### Errand chain into a meeting

```
before:Costco,Harmons
```

Use on a "Team meeting" event at Office. The incoming drive's first stop
becomes Costco (instead of going directly to Office). Chain detection
still uses the event's true location as B's incoming endpoint.

### Cross-town one-off

```
from:Sarah's
```

Use on an event when you're starting the day from somewhere other than
Home. The incoming origin is overridden and the event is excluded from
any chain it would otherwise inherit from a predecessor.

### Skip travel entirely

```
nonav
```

Use on virtual / on-site events that shouldn't trigger any drive
computation even though they have a `location` set.

## Where the Data Lands

Computed values are written into `metadata.travel` on both the
`AgendaItem` and its parent `AgendaSchedule` (so phantoms inherit):

| Key | Meaning |
|-----|---------|
| `travel_seconds` / `travel_minutes` | Incoming-leg drive duration. |
| `travel_from` / `travel_from_kind` | Where the incoming drive starts (`"home"` / `"event"` / `"override"`). |
| `leave_at` | Epoch — when to start driving for the incoming leg. |
| `post_travel_to` | `to:` destination text. |
| `post_travel_seconds` / `post_travel_minutes` | Post-event drive duration. |
| `post_arrive_at` | Epoch — when you'll arrive at `post_travel_to`. |
| `chain_predecessor_id` / `chain_successor_id` / `chain_head_id` | Chain pointers when this event is linked to a neighbour. |
| `overrides` | Echo of the parsed directives. |

Schedule-level travel is the **static slice** only (no chain pointers,
no time-anchored fields) — those are per-occurrence and meaningless on
a recurrence rule.
