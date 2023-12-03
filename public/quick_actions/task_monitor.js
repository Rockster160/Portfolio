// Make sure new objects sync the status correctly

import { Time } from './time.js';
import { AuthWS } from './auth_ws.js';

class Monitor {
  static #connected = false
  static #monitors = {}

  constructor(id, ele) {
    this.id = id
    this.ele = ele || Monitor.findEle(id)

    Monitor.#monitors[id] = this
  }

  static all() { return Object.values(Monitor.#monitors) }
  static find(id) {
    if (!id) { return }

    return Monitor.findMonitor(id) || new Monitor(id)
  }
  static findMonitor(id) {
    return Monitor.#monitors[id]
  }
  static findEle(id) {
    return document.querySelector(`.widget[data-type='monitor'][data-task-id='${id}']`)
  }
  static from(ele) {
    return Monitor.find(ele?.getAttribute("data-task-id"))
  }

  static get connected() { return Monitor.#connected }
  static set connected(bool) {
    Monitor.#connected = bool
    Monitor.updateStatus()
  }

  static updateStatus() {
    document.querySelectorAll(".widget[data-type='monitor'] .disconnected").forEach(item => {
      item.classList.toggle("hidden", Monitor.connected)
    })
  }

  static allAction(action) {
    document.querySelectorAll(".widget[data-type='monitor']").forEach(item => {
      let monitor = Monitor.find(item.getAttribute("data-task-id"))
      monitor.loading = true
      monitor.do(action)
    })
  }

  set loading(bool) { this.ele.querySelector(".loading").classList.toggle("hidden", !bool) }
  set content(lines) { this.ele.querySelector(".lines").textContent = lines }
  set timestamp(new_timestamp) { this.setTime(new_timestamp) }

  setTime(new_timestamp) {
    let monitor = this
    let sync = monitor.ele.querySelector(".last-sync")
    if (new_timestamp) { sync.setAttribute("data-timestamp", new_timestamp) }

    let timestamp = new_timestamp || parseInt(sync.getAttribute("data-timestamp"))
    if (timestamp) { sync.textContent = Time.timeAgo(timestamp) }
  }

  do(action) {
    let monitor = this
    monitor.loading = true
    Monitor.socket.send({ id: monitor.id, action: action })
  }
  execute() { this.do("execute") } // Runs task with executing:true
  refresh() { this.do("refresh") } // Runs task with executing:false
  resync()  { this.do("resync")  } // Pulls most recent result without Running
}
// Defining after class to help race conditions
Monitor.socket = new AuthWS("MonitorChannel", {
  onmessage: function(data) {
    console.log("MonitorChannel.onmessage", data);
    let monitor = Monitor.find(data.id)
    if (!monitor) { return }
    if (data.loading) { return monitor.loading = true }

    monitor.loading = false
    monitor.timestamp = data.timestamp * 1000
    monitor.content = data.result
  },
  onopen: function() {
    console.log("MonitorChannel.onopen");
    Monitor.connected = true
    Monitor.allAction("resync")
  },
  onclose: function() {
    console.log("MonitorChannel.onclose");
    Monitor.connected = false
  }
})

setInterval(function() {
  Monitor.all().forEach(monitor => monitor.setTime())
}, 1000)

document.addEventListener("click", function(evt) {
  let refreshBtn = evt.target.closest(".refresh")
  let monitor = Monitor.from(refreshBtn?.closest(".widget[data-type='monitor']"))
  if (monitor) { return monitor.refresh() }

  let wrapper = evt.target.closest(".widget-holder")
  monitor = Monitor.from(wrapper?.querySelector(".widget[data-type='monitor']"))
  if (monitor) { return monitor.execute() }
})
