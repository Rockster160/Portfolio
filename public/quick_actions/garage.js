import { AuthWS } from './auth_ws.js';
import { Widget } from './widget.js';

export let garage = new Widget("garage", function() {
  garage.loading = true
  switch (garage.state) {
    case "open": garage.socket.send({ action: "control", direction: "close" }); break;
    case "closed": garage.socket.send({ action: "control", direction: "open" }); break;
    default: garage.socket.send({ action: "control", direction: "toggle" }); break;
  }
})
if (garage.wrapper) {
  garage.socket = new AuthWS("GarageChannel", {
    onmessage: function(msg) {
      garage.loading = false
      if (msg.data?.garageState) {
        garage.state = msg.data.garageState

        garage.ele.classList.remove("open", "closed", "between")
        garage.ele.classList.add(garage.state)

        garage.last_sync = new Date()
      }
    },
    onopen: function() {
      garage.connected()
      garage.refresh()
    },
    onclose: function() {
      garage.disconnected()
    }
  })
  garage.refresh = function() {
    garage.loading = true
    garage.socket.send({ action: "request" })
  }
  garage.refresh()
  garage.tick = function() {
    if (garage.state == "between" && garage.delta() > 9 && garage.delta() % 5 == 0) {
      garage.refresh()
    }
  }
}
