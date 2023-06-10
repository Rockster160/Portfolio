import { registerNotifications } from "./push_subscribe.js";
import { AuthWS } from './auth_ws.js';
import { Widget } from './widget.js';
import { showModal } from './modal.js';
import { showFlash } from './flash.js';

let modal = document.querySelector("#command-modal")

function addMessage(direction, msg) {
  let div = document.createElement("div")
  div.classList.add("message")
  div.classList.add(direction)
  div.textContent = msg

  if (direction == "in") {
    showFlash(msg)
  }

  modal.querySelector(".messages").prepend(div)
}

export let command = new Widget("command", function() {
  showModal("command-modal")
  modal.querySelector("input").focus()
})
command.socket = new AuthWS("JarvisChannel", {
  onmessage: function(msg) {
    if (msg.say) { addMessage("in", msg.say) }
  },
  onopen: function() {
    command.connected()
  },
  onclose: function() {
    command.disconnected()
  }
})

modal.querySelector("input").addEventListener("keypress", function(evt) {
  if (evt.key == "Enter") {
    let input = modal.querySelector("input")

    if (input.value.toLowerCase().trim() == "reload") {
      // Do a full page cache reload
      return window.location.reload(true)
    }
    if (input.value.toLowerCase().trim() == "request notifications") {
      // Register Notifications
      addMessage("out", "Request notifications")
      input.value = ""
      registerNotifications().then(function() {
        console.log("Registering notifications");
        addMessage("in", "Registering for notifications...")
      })
      return
    }
    command.socket.send({ action: "command", words: input.value })
    addMessage("out", input.value)
    input.value = ""
  }
})
