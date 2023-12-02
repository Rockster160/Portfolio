import { command } from './command.js';

document.addEventListener("click", function(evt) {
  if (!evt.target.classList.contains("widget-holder")) { return }
  let cmd = evt.target.querySelector("[data-command]")?.getAttribute("data-command")
  if (!cmd) { return }
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
