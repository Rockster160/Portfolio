import { onEvent, onKeyDown } from "./events"

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

  // ==================== Key Press ====================
  onKeyDown("Backspace Delete", ":not(input)", function() {
    game.clearShot()
  })
  onKeyDown("Enter", ":not(input)", function() {
    finishFrame(false)
  })
  onKeyDown("ArrowUp", ":not(input)", function() {
    // same shot on prev bowler (wrapping)
    let shot = game.currentShot, frame = shot?.frame, bowler = frame?.bowler
    if (bowler) {
      let newBowlerNum = bowler.num - 1
      let newBowler = game.bowlers[newBowlerNum]
      newBowler = newBowler || game.bowlers[game.bowlers.length-1]
      game.currentShot = newBowler.frames[frame.frameNum].shots[shot.shotNum]
    }
  })
  onKeyDown("ArrowDown", ":not(input)", function() {
    // same shot on next bowler (wrapping)
    let shot = game.currentShot, frame = shot?.frame, bowler = frame?.bowler
    if (bowler) {
      let newBowlerNum = bowler.num + 1
      let newBowler = game.bowlers[newBowlerNum]
      newBowler = newBowler || game.bowlers[1]
      game.currentShot = newBowler.frames[frame.frameNum].shots[shot.shotNum]
    }
  })
  onKeyDown("ArrowLeft", ":not(input)", function() {
    // prev shot on current bowler (wrapping)
    let shot = game.currentShot, frame = shot?.frame, bowler = frame?.bowler
    if (bowler) {
      let newFrame = frame
      let newShot = newFrame.shots[shot.shotNum - 1]
      if (!newShot) {
        newFrame = bowler.frames[newFrame.frameNum - 1]
        if (!newFrame) { newFrame = bowler.frames[10] }
        newShot = newFrame.shots[newFrame.shots.length - 1]
      }
      game.currentShot = bowler.frames[newFrame.frameNum].shots[newShot.shotNum]
    }
  })
  onKeyDown("ArrowRight", ":not(input)", function() {
    let shot = game.currentShot, frame = shot?.frame, bowler = frame?.bowler
    if (bowler) {
      let newFrame = frame
      let newShot = newFrame.shots[shot.shotNum + 1]
      if (!newShot) {
        newFrame = bowler.frames[newFrame.frameNum + 1]
        if (!newFrame) { newFrame = bowler.frames[1] }
        newShot = newFrame.shots[1]
      }
      game.currentShot = bowler.frames[newFrame.frameNum].shots[newShot.shotNum]
    }
  })
  onKeyDown("1 2 3 4 5 6 7 8 9 0 / x X * -", ":not(input)", function(evt) {
    if (/\d/.test(evt.key)) {
      if (game.pinMode) {
        let key = parseInt(evt.key)
        key = key == 0 ? 10 : key
        game.pins.toggle(key)
        return
      } else {
        // pinMode: off - nums set the count of fallen pins
      }
    }
    if (evt.key == "-") {
      game.pins.standAll()
      finishFrame(false)
      return
    }
    if (/[x\/\*]/i.test(evt.key)) {
      finishFrame(true)
      return
    }
    console.log("num", evt.key)
  })

  // ==================== Pin Interactions ====================
  let pinKnocking = undefined // Means we are currently knocking pins down when true or standing when false

  // Disable holding for right click on mobile
  window.oncontextmenu = function(evt) {
    if (evt.target.classList.contains("pin")) {
      evt.preventDefault()
    }
  }
  // On click/tap, toggle a pin, track the toggle direction, and start the timer
  onEvent("mousedown touchstart", ".pin-wrapper:not(.fallen-before)", function(evt) {
    evt.preventDefault() // Disable screen drag/zoom events when tapping
    let pin = evt.target.closest(".pin-wrapper:not(.fallen-before)")
    if (pin) {
      // When a drag starts, freeze the timer so it doesn't move frames while knocking
      game.pinTimer.freeze()
      let pinNum = parseInt(pin.getAttribute("data-pin-num"))
      pinKnocking = game.pins.checkStanding(pinNum)
      game.pins.toggle(pinNum, !pinKnocking)
    }
    return false
  })
  // On release, unfreeze the timer
  onEvent("touchend mouseup", function() {
    if (pinKnocking !== undefined) {
      game.pinTimer.unfreeze()
      pinKnocking = undefined
    }
  })
  onEvent("mousemove", function(evt) {
    if (!game) { return }
    if (evt.which != 1) { return } // Left mouse is NOT held

    // Left click IS held
    // If hovering/dragging over a pin
    if (document.querySelector(".pin-wrapper:not(.fallen-before):hover")) {
      // evt.preventDefault()
      game.pinTimer.freeze()

      let pinWrapper = document.querySelector(".pin:hover").closest(".pin-wrapper")
      if (!pinWrapper) { return } // Pin was fallen-before, so can't toggle it

      if (pinKnocking == undefined) { // undefined is when we haven't clicked a pin yet
        pinKnocking = !pinWrapper.classList.contains("fallen")
      }
      // Toggle the pin the direction the first pin clicked was
      let pinNum = parseInt(pinWrapper.getAttribute("data-pin-num"))
      game.pins.toggle(pinNum, !pinKnocking)
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
