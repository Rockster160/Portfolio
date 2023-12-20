import consumer from "./../../../channels/consumer"
// import { Time } from './time.js';
// import { toMd } from './md_render.js';

// let socket = Monitor.subscribe(uuid, channel, { // Does NOT open a new channel, just subscribes to the listener
//   connected: function() {},
//   disconnected: function() {},
//   received: function(data) {},
// })
// socket.send({ foo: bar }) // Uses initial channel

export class Monitor {
  static #connected = false
  static #monitors = {}

  constructor(uuid, channel, callbacks) {
    console.log("New", uuid, channel, callbacks);
    this.uuid = uuid
    this.channel = channel
    this.callbacks = callbacks || {}

    Monitor.#monitors[uuid] = Monitor.#monitors[uuid] || []
    Monitor.#monitors[uuid].push(this)
  }

  static subscribe(uuid, channel, callbacks) {
    console.log("Subscribe");
    let monitor = new Monitor(uuid, channel, callbacks)
    if (Monitor.#connected) {
      console.log(".connected");
      monitor.connected()
    } else {
      console.log(".disconnected");
      monitor.disconnected()
    }

    return monitor
  }

  send(data) {
    data.channel = this.channel
    console.log("send", data);
    Monitor.socket.perform("broadcast", data)
  }

  static byUUID(uuid) { return Monitor.#monitors[uuid] || [] }

  static all() { return Object.values(Monitor.#monitors).flat() }

  static get connected() { return Monitor.#connected }
  static set connected(bool) {
    Monitor.#connected = bool
    // Monitor.all().forEach(item => item) // Do stuff
  }

  connected() {
    console.log("monitor.connected");
    let callback = this.callbacks.connected
    if (callback && typeof(callback) === "function") { callback.call(this) }
  }
  disconnected() {
    console.log("monitor.disconnected");
    let callback = this.callbacks.disconnected
    if (callback && typeof(callback) === "function") { callback.call(this) }
  }
  received(data) {
    console.log("monitor.received");
    let callback = this.callbacks.received
    if (callback && typeof(callback) === "function") { callback.call(this, data) }
  }
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
    console.log("MonitorChannel.received", data);
    Monitor.byUUID(data.id).forEach(item => item.received(data))
  },
})
window.Monitor = Monitor
