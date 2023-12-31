import Reactive from "./reactive"
import Spinner from "../spinner"

export default class PinTimer extends Reactive {
  constructor() {
    super() // Element is added dynamically
    this.pinTimer = undefined // The timer for auto-moving to next frame - corresponds to spinner
    this.timerDuration = 1000 // MS it takes after releasing the pin before moving to next frame
    this.spinner = new Spinner({
      size: 55,
      stroke: 5,
      duration: this.timerDuration,
      color: "#2196F3",
    })

    this.bool("freezeTimer", function(value) { // Don't do the countdown/auto-next frame while we're dragging
      this.reset()
    })
    this.freezeTimer = false

    this.bool("timerActive", function(value) { // The actual timer toggle
      this.element?.classList?.toggle("active", value)
      if (!value) { this.reset() }
    })
    this.timerActive = true
  }

  freeze() { if (!this.freezeTimer) { this.freezeTimer = true } }
  unfreeze() { if (this.freezeTimer) { this.freezeTimer = false } }

  clear(freeze) {
    if (freeze) { this.freezeTimer = true }
    this.pinTimer = clearTimeout(this.pinTimer)
    this.spinner.reset()
  }

  reset() {
    let self = this
    self.clear()

    if (!self.timerActive || self.freezeTimer) { return }

    self.spinner.start()
    self.pinTimer = setTimeout(function() {
      self.pinTimer = clearTimeout(self.pinTimer)
      if (self.timerActive) {
        game.nextShot()
      }
    }, self.timerDuration)
  }

  addTo(selector) {
    this.element = document.querySelector(selector)
    this.element.append(this.spinner.element)
  }
}
