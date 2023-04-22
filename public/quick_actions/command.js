import { AuthWS } from './auth_ws.js';
import { Widget } from './widget.js';
import { showModal } from './modal.js';

console.log("Command Start");

let modal = document.querySelector("#command-modal")

console.log("Command fn");
function addMessage(direction, msg) {
  let div = document.createElement("div")
  div.classList.add("message")
  div.classList.add(direction)
  div.textContent = msg

  modal.querySelector(".messages").prepend(div)
}

console.log("Command init");
export let command = new Widget("command", function() {
  showModal("command-modal")
  modal.querySelector("input").focus()
})
console.log("Command set socket");
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

console.log("Start timeout");
setTimeout(function() {
  console.log("Finish timeout");
  modal.querySelector("input").addEventListener("keypress", function(evt) {
    console.log("Added listener");
    if (evt.key == "Enter") {
      let input = modal.querySelector("input")
      command.socket.send({ action: "command", words: input.value })
      addMessage("out", input.value)
      input.value = ""
    } else {
      console.log(evt.key, evt.which);
    }
  })
}, 300)
