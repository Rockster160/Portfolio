// Maybe? When clicking, show loading indicator
// * Also show indicator when the task starts to run
// * Have to have another task with a cron that runs the monitor task.. Need to somehow pass "executing:true"
// Add event listeners here
// Make sure new objects sync the status correctly

import { Time } from './time.js';
import { AuthWS } from './auth_ws.js';

let monitor_connected = false
let monitor_socket = new AuthWS("MonitorChannel", {
  onmessage: function(data) {
    console.log("MonitorChannel.onmessage", data);
    let monitor = getMonitor(data.id)
    if (!monitor) { return }

    setLoading(monitor, false)
    setTime(monitor, data.timestamp * 1000)
    monitor.querySelector(".lines").textContent = data.result
  },
  onopen: function() {
    console.log("MonitorChannel.onopen");
    setStatus(true)
    allMonitorAction("resync")
  },
  onclose: function() {
    console.log("MonitorChannel.onclose");
    setStatus(false)
  }
})
let monitorExecute = function(monitor) { // Runs task with executing:true
  setLoading(monitor, true)
  monitor_socket.send({ id: monitor.getAttribute("data-task-id"), action: "execute" })
}
let monitorRefresh = function(monitor) { // Runs task with executing:false
  setLoading(monitor, true)
  monitor_socket.send({ id: monitor.getAttribute("data-task-id"), action: "refresh" })
}
let monitorResync = function(monitor) { // Pulls most recent result without Running
  setLoading(monitor, true)
  monitor_socket.send({ id: monitor.getAttribute("data-task-id"), action: "resync" })
}
let allMonitorAction = function(action) {
  document.querySelectorAll(".widget[data-type='monitor']").forEach(item => {
    let id = item.getAttribute("data-task-id")
    setLoading(getMonitor(id), true)
    monitor_socket.send({ id: id, action: action })
  })
}

let getMonitor = function(id) {
  return document.querySelector(`.widget[data-type='monitor'][data-task-id='${id}']`)
}

let setLoading = function(monitor, bool) {
  monitor?.querySelector(".loading")?.classList?.toggle("hidden", !bool)
}

let setStatus = function(bool) {
  monitor_connected = bool
  pushStatus()
}

let pushStatus = function() {
  document.querySelectorAll(".widget[data-type='monitor'] .disconnected").forEach(item => {
    item.classList.toggle("hidden", monitor_connected)
  })
}

let setTime = function(monitor, new_timestamp) {
  let sync = monitor.querySelector(".last-sync")
  if (new_timestamp) { sync.setAttribute("data-timestamp", new_timestamp) }

  let timestamp = new_timestamp || parseInt(sync.getAttribute("data-timestamp"))
  if (timestamp) { sync.textContent = Time.timeAgo(timestamp) }
}

setInterval(function() {
  document.querySelectorAll(".widget[data-type='monitor']").forEach(monitor => setTime(monitor))
}, 1000)

document.addEventListener("click", function(evt) {
  let refreshBtn = evt.target.closest(".refresh")
  let monitor = refreshBtn?.closest(".widget[data-type='monitor']")
  if (monitor) { return monitorRefresh(monitor) }

  let wrapper = evt.target.closest(".widget-holder")
  monitor = wrapper?.querySelector(".widget[data-type='monitor']")
  if (monitor) { return monitorExecute(monitor) }
})
