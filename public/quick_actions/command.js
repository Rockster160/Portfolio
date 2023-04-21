import { AuthWS } from './auth_ws.js';
import { Widget } from './widget.js';
import { showModal } from './modal.js';

export let command = new Widget("command", function() {
  showModal("command-modal")
  document.querySelector("#command-modal input").focus()
  setTimeout(function() {
    let modals = document.querySelectorAll(".modal")
    modals.forEach((modal) => {
      modal.style.height = window.visualViewport.height - 40 + "px"
    })
  }, 310)
})
