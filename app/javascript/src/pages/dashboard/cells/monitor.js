import consumer from "./../../../channels/consumer"

// let socket = Monitor.subscribe(channel, { // Does NOT open a new channel, just subscribes to the listener
//   connected: function() {},
//   disconnected: function() {},
//   received: function(data) {},
// })
// socket.send({ foo: bar }) // Sends to current Monitor, triggering the event

export class Monitor {
  static #connected = false
  static #monitors = {}

  constructor(channel, callbacks) {
    this.channel = channel
    this.callbacks = callbacks || {}

    Monitor.#monitors[channel] = Monitor.#monitors[channel] || []
    Monitor.#monitors[channel].push(this)
  }

  static subscribe(channel, callbacks) {
    let monitor = new Monitor(channel, callbacks)
    if (Monitor.#connected) {
      monitor.connected()
    } else {
      monitor.disconnected()
    }

    return monitor
  }

  send(data) {
    console.log("send", data);
    data.channel = this.channel
    Monitor.socket.perform("broadcast", data)
  }

  static byUUID(channel) { return Monitor.#monitors[channel] || [] }

  static all() { return Object.values(Monitor.#monitors).flat() }

  static get connected() { return Monitor.#connected }
  static set connected(bool) {
    Monitor.#connected = bool
    // Monitor.all().forEach(item => item) // Do stuff
  }

  connected() {
    let callback = this.callbacks.connected
    if (callback && typeof(callback) === "function") { callback.call(this) }
  }
  disconnected() {
    let callback = this.callbacks.disconnected
    if (callback && typeof(callback) === "function") { callback.call(this) }
  }
  received(data) {
    let callback = this.callbacks.received
    if (callback && typeof(callback) === "function") { callback.call(this, data) }
  }
  do(action) {
    let monitor = this
    monitor.loading = true
    Monitor.socket.perform(action, { id: monitor.id, channel: monitor.channel })
  }
  execute() { this.do("execute") } // Runs task with executing:true
  refresh() { this.do("refresh") } // Runs task with executing:false
  resync()  { this.do("resync")  } // Pulls most recent result without Running
}
// Defining after class to help race conditions
Monitor.socket = consumer.subscriptions.create({
  channel: "MonitorChannel"
}, {
  connected: function() {
    console.log("MonitorChannel.onopen");
    Monitor.connected = true
    Monitor.all().forEach(item => item.connected())
  },
  disconnected: function() {
    console.log("MonitorChannel.onclose");
    Monitor.connected = false
    Monitor.all().forEach(item => item.disconnected())
  },
  received: function(data) {
    Monitor.byUUID(data.id).forEach(item => item.received(data))
  },
})
window.Monitor = Monitor
