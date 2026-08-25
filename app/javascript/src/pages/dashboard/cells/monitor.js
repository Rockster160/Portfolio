import consumer from "./../../../channels/consumer";

// let socket = Monitor.subscribe(channel, { // Does NOT open a new channel, just subscribes to the listener
//   connected: function() {},
//   disconnected: function() {},
//   received: function(data) {},
// })
// socket.send({ foo: bar }) // Sends to current Monitor, triggering the event

export class Monitor {
  static #connected = false;
  static #monitors = {};
  static #cells = new Set();
  // Performs already sent in the current turn — see `do`.
  static #sent = new Set();

  constructor(channel, callbacks) {
    this.channel = channel;
    this.callbacks = callbacks || {};

    Monitor.#monitors[channel] = Monitor.#monitors[channel] || [];
    Monitor.#monitors[channel].push(this);
  }

  static subscribe(channel, callbacks) {
    let monitor = new Monitor(channel, callbacks);
    if (typeof Cell !== "undefined" && Cell.current) {
      Monitor.#cells.add(Cell.current);
      Cell.current.markWSConnected(Monitor.#connected);
    }
    if (Monitor.#connected) {
      monitor.connected();
    } else {
      monitor.disconnected();
    }

    return monitor;
  }

  static notifyCells() {
    Monitor.#cells.forEach((cell) => cell.markWSConnected(Monitor.#connected));
  }

  send(data) {
    console.log("send", data);
    data.channel = this.channel;
    Monitor.socket.perform("broadcast", data);
  }

  // Drop this listener. The socket is shared and stays open — every other
  // subscriber on this channel is untouched.
  //
  // Needed by anything that REPAINTS its subscribed elements rather than
  // binding them once on load. The trigger buttons guard on `wrapper.monitor`
  // and are never redrawn, so they never needed it; the kiosk pad rebuilds its
  // buttons whenever the routine list changes, and without this each rebuild
  // left the previous subscription in the registry, still receiving into a
  // node that had left the document.
  unsubscribe() {
    const list = Monitor.#monitors[this.channel];
    if (!list) return;

    const idx = list.indexOf(this);
    if (idx !== -1) list.splice(idx, 1);
  }

  static byUUID(channel) {
    return Monitor.#monitors[channel] || [];
  }

  static all() {
    return Object.values(Monitor.#monitors).flat();
  }

  static get connected() {
    return Monitor.#connected;
  }
  static set connected(bool) {
    Monitor.#connected = bool;
    // Monitor.all().forEach(item => item) // Do stuff
  }

  // Every fan-out over this bus is a plain forEach — `received` walks the
  // subscribers on one channel, the reconnect sweep walks all of them. A
  // callback that threw took the rest of that loop down with it, so a broadcast
  // "shared between" two subscribers reached only the one registered first, and
  // one broken cell could swallow the reconnect for the entire page. Each
  // subscriber is independent, so each gets its own frame; the error is still
  // reported rather than swallowed.
  #dispatch(name, args=[]) {
    let callback = this.callbacks[name];
    if (!callback || typeof callback !== "function") {
      return;
    }

    try {
      callback.apply(this, args);
    } catch (err) {
      console.error(`Monitor[${this.channel}] ${name} handler failed:`, err);
    }
  }

  connected() {
    this.#dispatch("connected");
  }
  disconnected() {
    this.#dispatch("disconnected");
  }
  received(data) {
    this.#dispatch("received", [data]);
  }
  do(action) {
    let monitor = this;
    monitor.loading = true;

    // Subscribers on a channel are separate objects asking the server the same
    // question, so anything that touches all of them at once — the reconnect
    // sweep, or a cell whose reloader and `connected` both land in one pass —
    // sent N identical performs and ran the Jil task N times over.
    //
    // Nothing is deferred: the first perform goes out synchronously, exactly as
    // before. Only the copies raised in the SAME turn are dropped, and the key
    // clears on the next microtask, so anything a later turn asks for is a real
    // second request and still gets sent. The key carries everything the
    // payload does — two monitors on one channel with different ids are two
    // questions, not one.
    let key = `${action}:${monitor.channel}:${monitor.id ?? ""}`;
    if (Monitor.#sent.has(key)) {
      return;
    }
    Monitor.#sent.add(key);
    queueMicrotask(() => Monitor.#sent.delete(key));

    Monitor.socket.perform(action, {
      id: monitor.id,
      channel: monitor.channel,
    });
  }
  execute() {
    this.do("execute");
  } // Runs task with executing:true
  refresh() {
    this.do("refresh");
  } // Runs task with executing:false
  resync() {
    this.do("resync");
  } // Pulls most recent result without Running
}
// Defining after class to help race conditions
Monitor.socket = consumer.subscriptions.create(
  {
    channel: "MonitorChannel",
    page: window.location.pathname + window.location.search,
  },
  {
    connected: function () {
      console.log("MonitorChannel.onopen");
      Monitor.connected = true;
      Monitor.notifyCells();
      Monitor.all().forEach((item) => item.connected());
    },
    disconnected: function () {
      console.log("MonitorChannel.onclose");
      Monitor.connected = false;
      Monitor.notifyCells();
      Monitor.all().forEach((item) => item.disconnected());
    },
    received: function (data) {
      Monitor.byUUID(data.id).forEach((item) => item.received(data));
    },
  },
);
window.Monitor = Monitor;

// ActionCable's built-in ConnectionMonitor only reopens after its 12s
// stale threshold elapses — that's a 5–10s "Disconnected" banner on a
// PWA that just came back from a long background. Force an immediate
// reopen on visibility-return when the page has been hidden long enough
// that the underlying socket has likely been killed by the OS.
let hiddenAt = 0;
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "hidden") {
    hiddenAt = Date.now();
    return;
  }
  if (!hiddenAt) return;
  const hiddenFor = Date.now() - hiddenAt;
  hiddenAt = 0;
  if (hiddenFor < 2000) return;
  try { consumer.connection.reopen(); } catch (_) {}
});
