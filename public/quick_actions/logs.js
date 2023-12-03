import { command } from './command.js';

document.addEventListener("click", function(evt) {
  let widget = evt.target.closest(".widget-holder")
  if (!widget) { return }
  let commander = widget.querySelector("[data-command]")
  let cmd = commander?.getAttribute("data-command")
  let page_cmd = commander?.getAttribute("data-page")
  if (page_cmd == ".reload") {
    return window.location.reload(true)
  }
  if (!cmd) { return }

  if (cmd.includes("{{")) {
    let req = cmd.match(/\{\{(.*?)\}\}/)[1].trim()
    if (req.length == 0) { req = "What is the text?" }
    let res = prompt(req).trim()
    if (res.length == 0) { return }
    cmd = cmd.replace(/\{\{(.*?)\}\}/, res)
  }

  command.socket.send({ action: "command", words: cmd })
})
