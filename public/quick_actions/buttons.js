import { command } from './command.js';

document.addEventListener("click", function(evt) {
  let wrapper = evt.target.closest(".widget-holder")
  if (!wrapper) { return }

  let widget = wrapper.querySelector(".widget")
  let page_cmd = widget.getAttribute("data-page")
  if (page_cmd == ".reload") { return window.location.reload(true) }

  let cmd = widget.getAttribute("data-command")
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
