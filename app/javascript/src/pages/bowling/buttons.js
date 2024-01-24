import { onEvent, onKeyDown } from "./events"

export function buttons() {
  // ==================== Button Toggles ====================
  onEvent("click", ".bowler-name", (evt) => {
    let bowler = game.bowlerFrom(evt.target)
    game.eachBowler(other => {
      if (other.bowlerNum == bowler.bowlerNum) {
        bowler.cardPoint = !bowler.cardPoint
      } else {
        other.cardPoint = false
      }
    })
  })
  onEvent("click", ".backspace &>", () => game.clearShot())
  onEvent("click", ".timer-toggle &>", () => game.pinTimer.timerActiveToggle())
  onEvent("click", ".bowling-edit &>", () => game.editBowlerToggle())
  onEvent("click", ".pin-all-toggle &>", () => game.defaultPinStandingToggle())
  onEvent("click", ".lanetalk-toggle &>", () => game.laneTalkEnabledToggle())
  onEvent("click", ".crosslane-toggle &>", () => game.crossLaneToggle())
  onEvent("click", ".pin-mode-toggle &>", () => game.pinModeToggle())
  onEvent("click", ".brooklyn-toggle &>", () => game.strikePoint = "brooklyn")
  onEvent("click", ".pocket-toggle &>", () => game.strikePoint = "pocket")
  onEvent("click", ".next-frame &>", () => finishFrame(false))
  onEvent("click", ".close-frame &>", () => finishFrame(true))
  onEvent("click", ".pocket-close &>", () => {
    game.strikePoint = "pocket"
    finishFrame(true)
  })
  onEvent("click", ".brooklyn-close", () => {
    game.strikePoint = "brooklyn"
    finishFrame(true)
  })
  onEvent("click", ".shot", function(evt) {
    let shotNum = parseInt(this.getAttribute("data-shot-idx"))+1
    let frameNum = parseInt(this.closest(".frame").getAttribute("data-frame"))
    let bowlerNum = parseInt(this.closest(".bowler").getAttribute("data-bowler"))
    let bowler = game.bowlers[bowlerNum]

    if (!bowler.active) { return }

    game.currentShot = bowler.frames[frameNum].shots[shotNum]
  })

  let finishFrame = function(knock_rest) {
    if (knock_rest) { game.pins.knockAll() }

    game.nextShot(true)
  }

  // ==================== Key Press ====================
  onKeyDown("Backspace Delete", ":not(input), .shot", function(evt) {
    game.clearShot()
  })
  onKeyDown("Enter", ":not(input), .shot", function(evt) {
    evt.preventDefault()
    evt.stopPropagation()
    finishFrame(false)
  })
  onKeyDown("ArrowUp", ":not(input), .shot", function(evt) {
    // same shot on prev bowler (wrapping)
    let shot = game.currentShot, frame = shot?.frame, bowler = frame?.bowler
    if (bowler) {
      let newBowlerNum = bowler.num - 1
      let newBowler = game.bowlers[newBowlerNum]
      newBowler = newBowler || game.bowlers[game.bowlers.length-1]
      game.currentShot = newBowler.frames[frame.frameNum].shots[shot.shotNum]
    }
  })
  onKeyDown("ArrowDown", ":not(input), .shot", function(evt) {
    // same shot on next bowler (wrapping)
    let shot = game.currentShot, frame = shot?.frame, bowler = frame?.bowler
    if (bowler) {
      let newBowlerNum = bowler.num + 1
      let newBowler = game.bowlers[newBowlerNum]
      newBowler = newBowler || game.bowlers[1]
      game.currentShot = newBowler.frames[frame.frameNum].shots[shot.shotNum]
    }
  })
  onKeyDown("ArrowLeft", ":not(input), .shot", function(evt) {
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
  onKeyDown("ArrowRight", ":not(input), .shot", function(evt) {
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
  onKeyDown("1 2 3 4 5 6 7 8 9 0 / x X * -", ":not(input), .shot", function(evt) {
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
  // When clicking on inputs, do not run the rest of the pin tracking.
  onEvent("mousedown touchstart", function(evt) {
    if (evt.target.tagName == "INPUT") {
      evt.stopPropagation()
    } else {
      document.activeElement.blur()
    }
  })
  // Do not submit when clicking enter on inputs
  onEvent("keydown", "input", function(evt) {
    if (evt.key == "Enter") {
      evt.preventDefault()
      evt.target.blur()
    }
  })

  let pinKnocking = undefined // Means we are currently knocking pins down when true or standing when false

  // Disable holding for right click on mobile
  window.oncontextmenu = function(evt) {
    if (evt.target.classList.contains("pin")) {
      evt.preventDefault()
    }
  }
  // On click/tap, toggle a pin, track the toggle direction, and start the timer
  let mouseDownEvt = function(xPos, yPos) {
    if (!game) { return }

    let pinWrapper = document.elementFromPoint(xPos, yPos).closest(".pin-wrapper")
    if (!pinWrapper) { return }
    if (pinWrapper.matches(".fallen-before")) { return }

    game.pinTimer.freeze()
    if (pinKnocking == undefined) { // undefined is when we haven't clicked a pin yet
      pinKnocking = !pinWrapper.classList.contains("fallen")
    }
    // Toggle the pin the direction the first pin clicked was
    let pinNum = parseInt(pinWrapper.getAttribute("data-pin-num"))
    game.pins.toggle(pinNum, !pinKnocking)
  }
  // Stop select from highlighting text and/or zooming
  onEvent("mousedown touchstart selectstart", function(evt) {
    if (evt.target.tagName == "INPUT") { return }

    evt.preventDefault()
  })
  // mouseover is a mobile Safari fix since it doesn't trigger `mousemove` or `touchmove`
  onEvent("mousedown mousemove mouseover", function(evt) {
    if (evt.target.tagName == "INPUT") { return }
    if (evt.which != 1) { return } // return unless holding left click

    mouseDownEvt(evt.clientX, evt.clientY)
  })
  onEvent("touchstart touchmove", function(evt) {
    if (evt.target.tagName == "INPUT") { return }
    if (evt.which == 1) { return } // Return if clicking (this is the touch/drag, not click)

    mouseDownEvt(evt.touches[0].pageX, evt.touches[0].pageY)
  })
  // On release, unfreeze the timer
  onEvent("mouseup touchend", function(evt) {
    if (evt.target.tagName == "INPUT") { return }
    if (pinKnocking !== undefined) {
      game.pinTimer.unfreeze()
      pinKnocking = undefined
    }
  })
}
