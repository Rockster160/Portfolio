import applyFrameModifiers from "./frame_modifiers"
// Show totals

// On shot click, reset timer


// resetPinTimer → game.pinTimer.reset()
export function events() {
  onEvent("pin:change", function() {
    game.currentShot.standingPins = game.pins.standing
    game.pinTimer.reset()
    // addScore(pins.length - next_pins.length, true, next_shot)
    // recalculateFrame(toss)
    // calcScores()
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
