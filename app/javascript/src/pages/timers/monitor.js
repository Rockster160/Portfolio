// MonitorChannel subscriber for Timers broadcasts.
//
// Two parallel subscription paths, both writing to the same store:
//
//   1) The shared dashboard Monitor (`Monitor.subscribe("timers", ...)`)
//      — keyed by the `id` field of the broadcast envelope. This is the
//      same dispatcher whisper/chores rely on.
//
//   2) A DEDICATED ActionCable subscription to MonitorChannel — set up
//      independently of the dashboard's. Belt-and-suspenders against any
//      delivery failure in (1).
//
// Both paths funnel into `handle()`, which is idempotent (the store's
// timestamp-based upsert dedupes), so double-delivery is harmless.

import { Monitor } from "../dashboard/cells/monitor";
import consumer from "../../channels/consumer";
import { getTabId } from "./offline_queue";

export function subscribeTimersChannel({ store, api, onBeep, onSound, onReconnect }) {
  const tabId = getTabId();
  let everConnected = false;
  let everDisconnected = false;

  function handle(envelope) {
    const data = envelope?.data;
    if (!data) return;
    if (data.actor_tab_id && data.actor_tab_id === tabId) return;

    if (data.reason === "beep") { onBeep?.(data.pattern); return; }
    if (data.reason === "sound") { onSound?.(); return; }

    if (data.deleted && data.timer_id != null) {
      store.removeTimer(data.timer_id);
      return;
    }

    if (data.timer && data.timer.id != null) {
      // force:true — the broadcast carries server-authoritative state.
      // Without this, a fresh-but-locally-stale Date.parse on existing
      // updated_at could reject the new payload, leaving the card
      // displaying old data even though the user's next tap proves the
      // server has already moved on (the chained-dial lag).
      store.upsertTimer(data.timer, { source: "broadcast", force: true });
      return;
    }

    // Any other broadcast — reorder, page touch, etc. — signals that
    // SOMETHING on the server changed. Trigger a delta sync to pull
    // whatever it was instead of silently dropping the envelope on the
    // floor when `timer_id` happens to be absent. (Previously the
    // `if (data.timer_id == null) return;` guard would drop reorder
    // broadcasts, leaving the other device with stale positions until
    // the next visibilitychange.)
    api.sync(store.lastSyncTs).then((diff) => {
      if (diff) store.applySync(diff);
    });
  }

  // Path 1 — dashboard's Monitor dispatcher.
  Monitor.subscribe("timers", {
    connected() {
      if (everConnected && everDisconnected && onReconnect) {
        try { onReconnect(); } catch (e) { /* ignore */ }
      }
      everConnected = true;
      everDisconnected = false;
    },
    disconnected() {
      if (everConnected) everDisconnected = true;
    },
    received(envelope) { handle(envelope); },
  });

  // Path 2 — dedicated subscription that bypasses the dashboard
  // dispatcher entirely. Filters by envelope.id === "timers" so it
  // ignores other tenants' broadcasts on the same channel.
  try {
    consumer.subscriptions.create(
      {
        channel: "MonitorChannel",
        page: window.location.pathname + window.location.search,
        timers_direct: true,
      },
      {
        received(envelope) {
          if (envelope?.id !== "timers") return;
          handle(envelope);
        },
      },
    );
  } catch (e) { /* dashboard path will still work */ }
}
