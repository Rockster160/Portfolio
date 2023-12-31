import applyFrameModifiers from "./frame_modifiers"
// Show totals

// resetPinTimer → game.pinTimer.reset()
export function events() {
  onEvent("pin:change", function() {
    game.currentShot.standingPins = game.pins.standing
    game.pinTimer.reset()

    applyFrameModifiers(game.currentFrame)
  })

  let recountPins = function() {
    // var toss = $(".shot.current")
    // var pins = $(".pin-wrapper:not(.fallen, .fallen-before)").map(function() {
    //   return parseInt($(this).attr("data-pin-num"))
    // }).toArray()
    // var first_throw = (shotIndex(toss) == 0 || (shotIndex(toss) == 1 && currentTossAtIdx(0).attr("data-score") == 10))
    //
    // applyFrameModifiers(toss)
    //
    // // Store the pins that are still standing in the current throw
    // toss.parents(".frame").find(".fallen-pins[data-shot-idx=" + toss.attr("data-shot-idx") + "]").val("[" + pins.join() + "]")
    // addScore($(".pin-wrapper.fallen:not(.fallen-before)").length, true)
    // // If pins have changed, knock down the ones for the next throw as well
    // if (first_throw) {
    //   var next_fallen = toss.parents(".frame").find(".fallen-pins[data-shot-idx=" + (shotIndex(toss) + 1) + "]")
    //   if (next_fallen.val().length > 0) {
    //     var next_pins = JSON.parse(next_fallen.val()).filter(function(pin) {
    //       return pins.includes(pin)
    //     })
    //
    //     next_fallen.val("[" + next_pins.join() + "]")
    //     var next_shot = toss.parents(".frame").find(".shot[data-shot-idx=" + (shotIndex(toss) + 1) + "]")
    //     addScore(pins.length - next_pins.length, true, next_shot)
    //   }
    // }
    //
    // recalculateFrame(toss)
    // calcScores()
  }
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
