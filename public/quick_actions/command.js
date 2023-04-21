import { AuthWS } from './auth_ws.js';
import { Widget } from './widget.js';

let modal = document.querySelector("#command-modal")
export let command = new Widget("command", function() {
  modal.classList.add("show")
})

document.querySelector("#command-modal .close").addEventListener("click", function(e) {
  const target = e.target.closest(".close")

  modal.classList.remove("show")
})
