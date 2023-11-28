import { AuthWS } from './auth_ws.js';
import { Widget } from './widget.js';
import { command } from './command.js';
import { showModal } from './modal.js';

document.querySelectorAll(".widget-modal").forEach((widget) => {
  let log = widget.getAttribute("data-modal")

  new Widget(log, function() {
    showModal(log)
  })
})

document.querySelectorAll(".mini-widget").forEach((widget) => {
  let id = widget.getAttribute("data-id")

  new Widget(id, function() {
    let cmd = widget.getAttribute("data-cmd")

    if (cmd == ".reload") {
      return window.location.reload(true)
    }

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
