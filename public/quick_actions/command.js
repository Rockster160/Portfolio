import { AuthWS } from './auth_ws.js';
import { Widget } from './widget.js';
import { showModal } from './modal.js';

export let command = new Widget("command", function() {
  showModal("command-modal")
  document.querySelector("#command-modal input").focus()
})
