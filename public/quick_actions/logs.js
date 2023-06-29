import { AuthWS } from './auth_ws.js';
import { Widget } from './widget.js';
import { command } from './command.js';
import { showModal } from './modal.js';

export let events = new Widget("events", function() {
  showModal("events-modal")
})

export let logs = new Widget("drugs", function() {
  showModal("drugs-modal")
})

export let care = new Widget("care", function() {
  showModal("care-modal")
})

document.querySelectorAll(".mini-widget").forEach((widget) => {
  let id = widget.getAttribute("data-id")

  new Widget(id, function() {
    let cmd = widget.getAttribute("data-cmd")

    if (cmd.includes("{{")) {
      let req = cmd.match(/\{\{(.*?)\}\}/)[1].trim()
      if (req.length == 0) { req = "What is the text?" }
      let res = prompt(req).trim()
      if (res.length == 0) { return }
      cmd = cmd.replace(/\{\{(.*?)\}\}/, res)
    }

    command.socket.send({ action: "command", words: cmd })
  })
})
