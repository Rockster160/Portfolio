// Make sure new Adding new Monitor sets the connected status correctly

import { Time } from './time.js';
import { AuthWS } from './auth_ws.js';
import { toMd } from './md_render.js';

export class Monitor {
  static #connected = false
  static #monitors = {}

  constructor(id) {
    this.id = id

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

  static resyncAll() { Monitor.allAction("resync") }
  static refreshAll() { Monitor.allAction("refresh") }
  static executeAll() { Monitor.allAction("execute") }
  static allAction(action) {
    document.querySelectorAll(".widget[data-type='monitor']").forEach(item => {
      let monitor = Monitor.find(item.getAttribute("data-task-id"))
      monitor.loading = true
      monitor.do(action)
    })
  }

  get element() {
    return this.ele || Monitor.findEle(this.id)
  }

  set loading(bool) { this.element?.querySelector(".loading")?.classList?.toggle("hidden", !bool) }
  set error(bool) {
    this.element?.setAttribute("data-error", "true")
    this.element?.querySelectorAll(".refresh, .last-sync, .disconnected, .loading")?.forEach(item => item.remove())
  }
  set content(lines) {
    let my_lines = this.element?.querySelector(".lines")
    if (!my_lines) { return }
    my_lines.innerHTML = lines
  }
  set timestamp(new_timestamp) { this.setTime(new_timestamp) }
  set blip(new_blip) {
    if (!this.element) { return }
    this.element.querySelector(".blip")?.remove()
    if (new_blip) {
      let span = document.createElement("span")
      span.classList.add("blip")
      span.textContent = new_blip
      this.element.appendChild(span)
    }
  }

  setTime(new_timestamp) {
    let monitor = this
    let sync = monitor.element?.querySelector(".last-sync")
    if (!sync) { return }
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
    if (data.error) {
      // data.result is set by the server
      monitor.content = toMd(data.result)
      return monitor.error = true
    }

    monitor.loading = false
    monitor.blip = data.blip
    monitor.timestamp = data.timestamp * 1000
    monitor.content = toMd(data.result)
  },
  onopen: function() {
    console.log("MonitorChannel.onopen");
    Monitor.connected = true
    Monitor.resyncAll()
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
  if (evt.cancelBubble) { return }

  let refreshBtn = evt.target.closest(".refresh")
  let monitor = Monitor.from(refreshBtn?.closest(".widget[data-type='monitor']"))
  if (monitor) {
    evt.preventDefault()
    evt.stopPropagation()
    monitor.refresh()
    return
  }

  let wrapper = evt.target.closest(".widget-holder")
  monitor = Monitor.from(wrapper?.querySelector(".widget[data-type='monitor']"))
  if (monitor) {
    evt.preventDefault()
    evt.stopPropagation()
    monitor.execute()
    return
  }
})

window.addEventListener("load", function() {
  setTimeout(function() {
    document.querySelectorAll(".widget[data-type='monitor'] .loading:not(.hidden)").forEach(item => {
      Monitor.from(item.closest(".widget"))?.resync()
    })
  }, 500)
})
