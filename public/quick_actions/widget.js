import { Time } from './time.js';

let widgets = {}

export class Widget {
  #last_sync = 0
  constructor(name, touch_callback) {
    let widget = this
    this.name = name
    this.ele = document.querySelector(`.widget.${name}, .widget[data-modal=${name}]`)
    this.last_sync = 0
    this.wrapper = this.ele?.parentElement

    if (!this.wrapper) { return }

    if (this.ele.getAttribute("data-type") == "monitor") {
      if (touch_callback && typeof(touch_callback) === "function") {
        this.wrapper.addEventListener("click", function(evt) {
          if (evt.cancelBubble) { return }
          touch_callback(evt)
        })
        this.wrapper.addEventListener("ontouchstart", function(evt) {
          if (evt.cancelBubble) { return }
          touch_callback(evt)
        })
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
    }

    widgets[name] = this
  }

  get last_sync() { return this.#last_sync }
  set last_sync(timestamp) {
    this.#last_sync = timestamp
    this.updateTimestamp()
  }
  set loading(bool) {
    this.wrapper?.querySelector(".loading")?.classList?.toggle("hidden", !bool)
  }
  set error(bool) {
    this.wrapper?.querySelector(".error")?.classList?.toggle("hidden", !bool)
  }
  set lines(new_lines) {
    if (!this.wrapper) { return }
    this.wrapper.querySelector(".lines").innerHTML = new_lines.map(function(line) {
      return `<p>${line}</p>`
    }).join("")
  }
  updateTimestamp() {
    if (!this.ele?.querySelector(".last-sync")) { return }

    this.ele.querySelector(".last-sync").textContent = Time.timeago(this.#last_sync)
  }
  delta() {
    if (this.#last_sync == 0) { return }

    return Math.round(((new Date()).getTime() - this.#last_sync) / 1000)
  }
  connected() {
    if (!this.wrapper) { return }

    this.wrapper.querySelector(".disconnected").classList.add("hidden")
  }
  disconnected() {
    if (!this.wrapper) { return }

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
