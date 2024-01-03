import applyFrameModifiers from "./frame_modifiers"

// resetPinTimer → game.pinTimer.reset()
export function events() {
  onEvent("pin:change", function() {
    game.currentShot.standingPins = game.pins.standing
  })
  onEvent("frame:change", function() {
    applyFrameModifiers(game.currentFrame)
  })
}

export function onEvent(events, selector, callback) {
  if (selector && typeof selector == "function") {
    callback = selector
    selector = null
  }

  events.split(" ").forEach(event => {
    document.addEventListener(event, function(evt) {
      if (selector) {
        let ele = evt.target.closest(selector)
        if (ele) { callback.call(ele, evt) }
      } else {
        callback.call(this, evt)
      }
    })
  })
}
