import { onEvent } from "./events"

export function buttons() {

  // ==================== Button Toggles ====================
  onEvent("click", ".backspace", function() { game.clearShot() })
  onEvent("click", ".timer-toggle", function() { game.pinTimer.timerActiveToggle() })
  onEvent("click", ".bowling-edit", function() { game.editBowlerToggle() })
  onEvent("click", ".pin-all-toggle", function() { game.defaultPinStandingToggle() })
  onEvent("click", ".lanetalk-toggle", function() { game.laneTalkToggle() })
  onEvent("click", ".pin-mode-toggle", function() { game.pinModeToggle() })
  onEvent("click", ".brooklyn-toggle", function() { game.strikePoint = "brooklyn" })
  onEvent("click", ".pocket-toggle", function() { game.strikePoint = "pocket" })
  onEvent("click", ".next-frame", function() { finishFrame(false) })
  onEvent("click", ".close-frame", function() { finishFrame(true) })
  onEvent("click", ".pocket-close", function() {
    game.strikePoint = "pocket"
    finishFrame(true)
  })
  onEvent("click", ".brooklyn-close", function() {
    game.strikePoint = "brooklyn"
    finishFrame(true)
  })
  onEvent("click", ".shot", function() {
    let shotNum = parseInt(this.getAttribute("data-shot-idx"))+1
    let frameNum = parseInt(this.closest(".frame").getAttribute("data-frame"))
    let bowlerNum = parseInt(this.closest(".bowler").getAttribute("data-bowler"))

    game.currentShot = game.bowlers[bowlerNum].frames[frameNum].shots[shotNum]
  })

  let finishFrame = function(knock_rest) {
    let frame = game.currentFrame
    if (knock_rest) { game.pins.knockAll() }

    game.nextShot(true)
    // We skip callbacks, so pins don't get "knocked" to apply frame modifiers
    // grab the current frame before nextShot since it changes the frame
    applyFrameModifiers(frame)
  }

  // ==================== Pin Interactions ====================
  let pinKnocking = undefined // Means we are currently knocking pins down when true or standing when false

  // Disable holding for right click on mobile
  window.oncontextmenu = function(evt) {
    if (evt.target.classList.contains("pin")) {
      evt.preventDefault()
    }
  }
  // On click/tap, toggle a pin, track the toggle direction, and start the timer
  onEvent("mousedown touchstart", ":not(input, label)", function(evt) {
    if (evt.target.closest(".numpad-key")) { return }

    evt.preventDefault()
    let pin = evt.target.closest(".pin-wrapper:not(.fallen-before)")
    if (pin) {
      if (evt.type == "touchstart") {
        // Only freeze timer for touch events, wait for the drag to finish to release
        game.pinTimer.freezeTimer = true
      }

      let pinNum = parseInt(pin.getAttribute("data-pin-num"))
      pinKnocking = game.pins.checkStanding(pinNum)
      game.pins.toggle(pinNum, !pinKnocking)
    }
    return false
  })
  // On release, unfreeze the timer
  onEvent("touchend mouseup", function() {
    if (game.pinTimer.freezeTimer) { game.pinTimer.freezeTimer = false }
    pinKnocking = undefined
  })
  // Disable touchends on pins?
  onEvent("touchend", ".pin", function(evt) {
    evt.preventDefault()
  })
  onEvent("mousemove", function(evt) {
    if (!game) { return }
    if (evt.which != 1) { // Left mouse is NOT held
      if (game.pinTimer.freezeTimer) { game.pinTimer.freezeTimer = false }
      return
    }
    // Left click IS held
    let pin = evt.target.closest(".pin-wrapper:not(.fallen-before)")
    if (pin && !game.pinTimer.freezeTimer) {
      // If we're clicking/dragging
      game.pinTimer.freezeTimer = true
    }

    // If hovering over a pin
    if (document.querySelector(".pin-wrapper:not(.fallen-before):hover")) {
      evt.preventDefault()
      let pinWrapper = document.querySelector(".pin:hover").closest(".pin-wrapper")
      if (!pinWrapper) { return } // Pin was fallen-before, so can't toggle it

      let pinNum = parseInt(pinWrapper.getAttribute("data-pin-num"))
      if (pinKnocking == undefined) {
        // Set direction to the first pin hit
        pinKnocking = !pinWrapper.classList.contains("fallen")
      } else {
        // Toggle the pin the direction the first pin clicked was
        game.pins.toggle(pinNum, !pinKnocking)
      }
    }
  })
  // Is this needed? Maybe for the ipad?
  //   $(".bowling-keypad-entry").on("mousemove, touchmove", function(evt) {
  //     evt.preventDefault()
  //     var xPos = evt.originalEvent.touches[0].pageX
  //     var yPos = evt.originalEvent.touches[0].pageY
  //
  //     var $target = $(document.elementFromPoint(xPos, yPos))
  //     if (!$target.hasClass("pin")) { return }
  //
  //     if (pin_knock == undefined) {
  //       pin_knock = !$target.parents(".pin-wrapper:not(.fallen-before)").hasClass("fallen")
  //     } else if (pin_knock) {
  //       $target.parents(".pin-wrapper:not(.fallen-before)").addClass("fallen").trigger("pin:change")
  //     } else {
  //       $target.parents(".pin-wrapper:not(.fallen-before)").removeClass("fallen").trigger("pin:change")
  //     }
  //     return false
  //   })
}
