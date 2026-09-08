// A stable name for THIS install, sent with every push subscription.
//
// The endpoint can't be that name. iOS revokes a push subscription whenever a
// push arrives that shows no notification, and the device comes back with a
// fresh endpoint — so keyed on the endpoint, one phone filed itself as a new
// device several times a day and the server fanned every push out across a
// pile of addresses nothing was listening to.
//
// localStorage is per-origin, so Byte and Whisper (own subdomains) each get
// their own id, while the apex apps — Jarvis, Agenda, Timers, Chores — share
// one. That's correct either way: rows are keyed on (user, channel, device_id),
// so one install holds exactly one row per channel.
//
// Copied, not imported, in two places that can't reach this module:
// `public/quick_actions/push_subscribe.js` (served raw, outside the bundle) and
// the inline script in `app/views/chores/_page_script.html.erb`. The KEY is
// what has to match, and it does.
const DEVICE_ID_KEY = "push-device-id";

export function pushDeviceId() {
  try {
    let id = localStorage.getItem(DEVICE_ID_KEY);
    if (!id) {
      id = crypto.randomUUID();
      localStorage.setItem(DEVICE_ID_KEY, id);
    }
    return id;
  } catch (_) {
    // Private mode, blocked storage — the server falls back to matching on the
    // endpoint, which is exactly what it did before any of this existed.
    return null;
  }
}
