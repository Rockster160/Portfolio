import Reactive from "./reactive"

export default class Frame extends Reactive {
  static fullGame(bowler) {
    let allFrames = Array.from({ length: 10 }, (_, idx) => idx+1).map(frameNum => {
      return new Frame(bowler, frameNum)
    })
    allFrames.unshift(null) // Add empty space at the beginning of the array to align num to idx
    return allFrames
  }

  constructor(bowler, frameNum) {
    super(bowler.element.querySelector(`.frame[data-frame="${frameNum}"]`))
    this.bowler = bowler // Do we need this?
    this.frameNum = frameNum

    this.firstShot = new Shot(this, 1)
    this.secondShot = new Shot(this, 2)
    if (frameNum == 10) {
      this.thirdShot = new Shot(this, 3)
    }

    this.accessor("strikePoint", ".strike-point", "value", function(val) {
      document.querySelector(".pocket-toggle").classList.toggle("active", val == "pocket")
      document.querySelector(".brooklyn-toggle").classList.toggle("active", val == "brooklyn")
    })
  }

  resetStrikePoint() { this.strikePoint = this.strikePoint }

  get shots() {
    if (this.isLastFrame) {
      return [null, this.firstShot, this.secondShot, this.thirdShot]
    } else {
      return [null, this.firstShot, this.secondShot]
    }
  }

  currentShot() {
    if (this.firstShot.incomplete) { return this.firstShot }
    if (!this.isLastFrame) {
      if (this.firstShot.knockedAll) { return this.firstShot } // Just reselect the first
      return this.secondShot
    } else { // 10th frame
      if (this.secondShot.incomplete) { return this.secondShot }
      if (this.secondShot.knockedAll || this.firstShot.knockedAll) {
        if (this.thirdShot.incomplete) { return this.thirdShot }
      }
    }

    return this.firstShot
  }

  get isLastFrame() { return this.frameNum == 10 }

  finished() {
    if (this.firstShot.incomplete) { return false }
    if (!this.isLastFrame) {
      return this.firstShot.knockedAll || this.secondShot.complete
    }
    // 10th frame logic
    // If 3rd is complete, then we're done
    if (this.thirdShot.complete) { return true }
    // If 1st is strike, there will be a 3rd, so we're not done
    if (this.firstShot.knockedAll) { return false }
    // If 2nd is closed, there will be a 3rd, so we're not done
    return this.secondShot.knockedAll
  }
}

class Shot extends Reactive {
  constructor(frame, shot_num) {
    super(frame.element.querySelector(`.shot[data-shot-idx="${shot_num-1}"]`))
    this.remaining_pins_element = frame.element.querySelector(`.fallen-pins[data-shot-idx="${shot_num-1}"]`)
    this.shotNum = shot_num
    this.frame = frame

    this.clear()
  }

  clear() {
    this.complete = false
    this.pinFallCount = undefined
    this._fallen_pins = undefined
    this._knocked_all = false
    this.element.value = ""
    this.remaining_pins_element.value = ""
  }

  get incomplete() { return !this.complete }
  get knockedAll() { return this._knocked_all }

  get standingPins() { return game.pins.invert(this.fallenPins) }
  set standingPins(standing_pins) { this.fallenPins = game.pins.invert(standing_pins) }

  get fallenPins() { return this._fallen_pins }
  set fallenPins(fallen_pins) {
    let prevShot = this.prevShot()
    if (prevShot) {
      if (prevShot.incomplete) { prevShot.fallenPins = [] }
      // Do not allow setting fallen pins to pins that were already fallen in the last shot
      let prev_standing_pins = prevShot.standingPins
      let newlyFallenPins = fallen_pins.filter(pin => prev_standing_pins.includes(pin))
      fallen_pins = [...newlyFallenPins, ...prevShot.fallenPins]
    }
    this._fallen_pins = fallen_pins

    this.complete = true
    let standing_pins = game.pins.invert(fallen_pins)
    this.remaining_pins_element.value = `[${standing_pins.join()}]`
    this.pinFallCount = fallen_pins.length
    this._knocked_all = this.pinFallCount == 10
    let prevCount = prevShot?.pinFallCount || 0
    let str = this.pinFallCount - prevCount

    if (str == 0) {
      str = "-"
    } else if (this.shotNum == 1) {
      if (this.knockedAll) { str = "X" }
    } else if (this.shotNum == 2 && !this.frame.isLastFrame) {
      if (this.knockedAll) { str = "/" }
    } else if (this.shotNum == 2) { // 10th frame
      if (this.frame.firstShot.knockedAll) {
        str = "X"
      } else if (this.knockedAll) {
        str = "/"
      }
    } else if (this.shotNum == 3) {
      if (this.frame.secondShot.knockedAll) {
        if (this.knockedAll) { str = "X" }
      } else if (this.frame.firstShot.knockedAll) {
        if (this.knockedAll) { str = "/" }
      }
    }

    this.element.value = str
    this.remaining_pins_element.value = `[${this.standingPins.join()}]`
    // Knock next shot pins over if knocked here
    // TODO: Add 10th frame logic
    if (this.frame.isLastFrame) { return } // This will have weird behavior on the 10th frame
    if (this.shotNum == 2) { return } // 10th is skipped, so 2nd shot is last, so no need to check
    // Remove the 2 above checks after 10th frame logic is added

    let nextShot = this.frame.secondShot
    if (nextShot.incomplete) { return } // If it's not filled in, don't do anything
    // Remove all of the fallen pins from the next shot, if present
    nextShot.fallenPins = nextShot.fallenPins.filter(pin => !fallen_pins.includes(pin))
  }

  prevShot() {
    if (this.shotNum == 1) { return }
    if (!this.frame.isLastFrame) { return this.frame.firstShot }
    // 10th frame
    if (this.shotNum == 2) {
      return this.frame.firstShot.knockedAll ? null : this.frame.firstShot
    } else if (this.shotNum == 3) {
      if (this.frame.firstShot.knockedAll) { // 1st closed
        return this.frame.secondShot.knockedAll ? null : this.frame.secondShot
      } else { // 1st open
        return this.frame.secondShot
      }
    }
  }
}
