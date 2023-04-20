import { AuthWS } from './quick_actions/auth_ws.js';
import { Widget } from './quick_actions/widget.js';

let garage = new Widget("garage", function() {
  garage.loading = true
  switch (garage.state) {
    case "open": garage.socket.send({ action: "control", direction: "close" }); break;
    case "closed": garage.socket.send({ action: "control", direction: "open" }); break;
    default: garage.socket.send({ action: "control", direction: "toggle" }); break;
  }
})
garage.socket = new AuthWS("GarageChannel", {
  onmessage: function(msg) {
    if (msg.data?.garageState) {
      garage.loading = false
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
garage.refresh = function() { garage.socket.send({ action: "request" }) }
garage.refresh()
garage.tick = function() {
  if (garage.state == "between" && garage.delta() > 9 && garage.delta() % 5 == 0) {
    garage.refresh()
  }
}
