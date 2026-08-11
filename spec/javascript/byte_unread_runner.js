// Feeds message shapes through the unread tracker and prints the results as
// JSON for byte_unread_spec.rb. No DOM — UnreadTracker and countsAsUnread are
// pure.
import {
  UnreadTracker,
  countsAsUnread,
  previewOf,
} from "../../app/javascript/src/pages/byte/unread.js";

const msg = (over = {}) => ({
  id: 1,
  direction: "inbound",
  state: "delivered",
  metadata: {},
  body: "hello",
  ...over,
});

const out = {};

// ---- what counts ----------------------------------------------------------
out.counts = {
  settled_inbound: countsAsUnread(msg()),
  streaming: countsAsUnread(msg({ state: "streaming" })),
  pending: countsAsUnread(msg({ state: "pending" })),
  queued: countsAsUnread(msg({ state: "queued" })),
  sent: countsAsUnread(msg({ state: "sent" })),
  failed: countsAsUnread(msg({ state: "failed" })),
  outbound: countsAsUnread(msg({ direction: "outbound" })),
  activity_chip: countsAsUnread(msg({ metadata: { kind: "buddy_activity" } })),
  action_chip: countsAsUnread(msg({ metadata: { kind: "action_chip" } })),
  trigger_seed: countsAsUnread(msg({ metadata: { kind: "buddy_trigger" } })),
  hidden: countsAsUnread(msg({ metadata: { hidden: true } })),
  claude_reply: countsAsUnread(msg({ metadata: { kind: "claude" } })),
  relay: countsAsUnread(msg({ metadata: { kind: "buddy_relay" } })),
};

// ---- the bug: a long Claude turn ------------------------------------------
// One reply, re-broadcast on a throttle as its text grows, then settling. The
// old counter added one per broadcast; this is what that looked like.
{
  const t = new UnreadTracker();
  const notified = [];
  for (let i = 0; i < 25; i += 1) {
    notified.push(t.add(7, msg({ id: 99, state: "streaming", body: `working ${i}` })));
  }
  out.streaming_run_count = t.countFor(7);
  out.streaming_run_notices = notified.filter(Boolean).length;

  // It finishes.
  const settled = t.add(7, msg({ id: 99, state: "delivered", body: "all done" }));
  out.after_settle_count = t.countFor(7);
  out.settle_notified = settled;

  // A late edit re-broadcasts the same row.
  t.add(7, msg({ id: 99, state: "delivered", body: "all done (edited)" }));
  out.after_rebroadcast_count = t.countFor(7);
}

// ---- ordinary accumulation ------------------------------------------------
{
  const t = new UnreadTracker();
  t.add(1, msg({ id: 10 }));
  t.add(1, msg({ id: 11 }));
  t.add(2, msg({ id: 12 }));
  out.per_conversation = { one: t.countFor(1), two: t.countFor(2) };
  out.total = t.total();
  out.conversation_count = t.conversationCount();

  t.clear(1);
  out.after_clear = { one: t.countFor(1), total: t.total() };
}

// ---- onChange fires only on real change -----------------------------------
{
  let changes = 0;
  const t = new UnreadTracker({ onChange: () => { changes += 1; } });
  t.add(3, msg({ id: 20 }));
  t.add(3, msg({ id: 20 }));                       // same message again
  t.add(3, msg({ id: 21, state: "streaming" }));   // not settled
  out.change_events = changes;
}

// ---- the server's counts surviving a reload -------------------------------
{
  const t = new UnreadTracker();
  t.seedAll(
    [
      { id: 1, unread_count: 3 },
      { id: 2, unread_count: 1 },
      { id: 3, unread_count: 0 },
      { id: 4, unread_count: 9 },
    ],
    { except: 4 },
  );
  out.seeded = {
    one: t.countFor(1),
    two: t.countFor(2),
    three: t.countFor(3),
    current_skipped: t.countFor(4),
    total: t.total(),
    conversations: t.conversationCount(),
  };

  // Live arrivals stack on top of what the server already counted.
  t.add(1, msg({ id: 500 }));
  out.seed_plus_live = t.countFor(1);

  // Reading it clears BOTH halves — the server's marker moved at the same time,
  // so leaving the base behind would double-count on the next seed.
  t.clear(1);
  out.after_read = { one: t.countFor(1), total: t.total() };
}

// A re-seed must not clobber live arrivals: the server's number was computed
// before they landed.
{
  const t = new UnreadTracker();
  t.seedAll([{ id: 1, unread_count: 2 }]);
  t.add(1, msg({ id: 600 }));
  t.seedAll([{ id: 1, unread_count: 2 }]); // stale count arrives
  out.reseed_keeps_live = t.countFor(1);
}

// ...but a thread with nothing live DOES take the newer number, which is how a
// backgrounded session catches up on what it never saw broadcast.
{
  const t = new UnreadTracker();
  t.seedAll([{ id: 1, unread_count: 2 }]);
  t.seedAll([{ id: 1, unread_count: 5 }]);
  out.reseed_catches_up = t.countFor(1);
}

// ---- preview --------------------------------------------------------------
out.preview = {
  markdown: previewOf(msg({ body: "Sent **game_tray-vase** to the printer" })),
  code: previewOf(msg({ body: "the listener is `item:name:/x/` there" })),
  html: previewOf(msg({ body: "<span class=\"x\">ls -la</span> done" })),
  mood_marker: previewOf(msg({ body: "[[mood:happy]]Kk! TV's off." })),
  newlines: previewOf(msg({ body: "one\n\ntwo\nthree" })),
  empty: previewOf(msg({ body: "" })),
  long: previewOf(msg({ body: "x".repeat(200) })),
};

process.stdout.write(JSON.stringify(out, null, 2));
