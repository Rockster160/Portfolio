import { AuthWS } from './quick_actions/auth_ws.js';

let widgets = {}

class Widget {
  #last_sync = 0
  constructor(name, touch_callback) {
    let widget = this
    this.name = name
    this.ele = document.querySelector(`.widget.${name}`)
    this.last_sync = 0

    if (touch_callback && typeof(touch_callback) === "function") {
      this.ele.parentElement.addEventListener("click", touch_callback)
      this.ele.parentElement.addEventListener("ontouchstart", touch_callback)
    }
    let refresh_btn = this.ele.parentElement.querySelector(".refresh")
    refresh_btn.addEventListener("click", function(evt) {
      evt.stopPropagation()
      widget.refresh()
    })
    refresh_btn.addEventListener("ontouchstart", function(evt) {
      evt.stopPropagation()
      widget.refresh()
    })

    widgets[name] = this
  }

  get last_sync() { return this.#last_sync }
  set last_sync(timestamp) {
    this.#last_sync = timestamp
    this.updateTimestamp()
  }
  updateTimestamp() {
    this.ele.querySelector(".last-sync").textContent = timeAgo(this.#last_sync)
  }
  delta() {
    if (this.#last_sync == 0) { return }

    return Math.round(((new Date()).getTime() - this.#last_sync) / 1000)
  }
  connected() {
    this.ele.parentElement.querySelector(".disconnected").classList.add("hidden")
  }
  disconnected() {
    this.ele.parentElement.querySelector(".disconnected").classList.remove("hidden")
  }
}

function timeAgo(input) {
  const date = (input instanceof Date) ? input : new Date(input);
  if (date.getTime() == 0) { return "never" }
  const formatter = new Intl.RelativeTimeFormat('en');
  const ranges = {
    years: 3600 * 24 * 365,
    months: 3600 * 24 * 30,
    weeks: 3600 * 24 * 7,
    days: 3600 * 24,
    hours: 3600,
    minutes: 60,
    seconds: 1
  };
  const secondsElapsed = (date.getTime() - Date.now()) / 1000;
  for (let key in ranges) {
    if (ranges[key] < Math.abs(secondsElapsed)) {
      const delta = secondsElapsed / ranges[key];
      return formatter.format(Math.round(delta), key);
    }
  }
  return "just now"
}

let garage = new Widget("garage", function() {
  switch (garage.state) {
    case "open": garage.socket.send({ action: "control", direction: "close" }); break;
    case "closed": garage.socket.send({ action: "control", direction: "open" }); break;
    default: garage.socket.send({ action: "control", direction: "toggle" }); break;
  }
})
garage.socket = new AuthWS("GarageChannel", {
  onmessage: function(msg) {
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
garage.refresh = function() { garage.socket.send({ action: "request" }) }
garage.refresh()
garage.tick = function() {
  if (garage.state == "between" && garage.delta() > 9 && garage.delta() % 5 == 0) {
    garage.refresh()
  }
}

setInterval(function() {
  Object.keys(widgets).forEach(function(name) {
    let widget = widgets[name]
    widget.updateTimestamp()
    if (widget.tick && typeof(widget.tick) === "function") { widget.tick() }
  })
}, 1000)
