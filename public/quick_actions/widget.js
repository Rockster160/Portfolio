let widgets = {}

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

export class Widget {
  #last_sync = 0
  constructor(name, touch_callback) {
    let widget = this
    this.name = name
    this.ele = document.querySelector(`.widget.${name}, .widget[data-modal=${name}]`)
    this.wrapper = this.ele.parentElement
    this.last_sync = 0

    if (touch_callback && typeof(touch_callback) === "function") {
      this.wrapper.addEventListener("click", touch_callback)
      this.wrapper.addEventListener("ontouchstart", touch_callback)
    }
    let refresh_btn = this.wrapper.querySelector(".refresh")
    refresh_btn?.addEventListener("click", function(evt) {
      evt.stopPropagation()
      widget.refresh()
    })
    refresh_btn?.addEventListener("ontouchstart", function(evt) {
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
  set loading(bool) {
    this.wrapper.querySelector(".loading").classList.toggle("hidden", !bool)
  }
  set error(bool) {
    this.wrapper.querySelector(".error").classList.toggle("hidden", !bool)
  }
  set lines(new_lines) {
    this.wrapper.querySelector(".lines").innerHTML = new_lines.map(function(line) {
      return `<p>${line}</p>`
    }).join("")
  }
  updateTimestamp() {
    if (!this.ele.querySelector(".last-sync")) { return }

    this.ele.querySelector(".last-sync").textContent = timeAgo(this.#last_sync)
  }
  delta() {
    if (this.#last_sync == 0) { return }

    return Math.round(((new Date()).getTime() - this.#last_sync) / 1000)
  }
  connected() {
    this.wrapper.querySelector(".disconnected").classList.add("hidden")
  }
  disconnected() {
    this.wrapper.querySelector(".disconnected").classList.remove("hidden")
  }
}

setInterval(function() {
  Object.keys(widgets).forEach(function(name) {
    let widget = widgets[name]
    widget.updateTimestamp()
    if (widget.tick && typeof(widget.tick) === "function") { widget.tick() }
  })
}, 1000)
