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
    this.bowler = bowler
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

  get siblings() {
    return game.bowlers.map(bowler => bowler && bowler.frames[this.frameNum]).filter(Boolean)
  }
  get activeSiblings() {
    return this.siblings.filter(sibling => !sibling.bowler.absent && !sibling.bowler.skip)
  }

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

  fillRandom() {
    while (!this.complete) {
      if (Math.random() < 0.05) {
        this.currentShot().score = "-"
      } else if (Math.random() < 0.3) {
        // Keep 3/10 pins, on average
        this.currentShot().standingPins = game.pins.allPins.filter(pinNum => Math.random() < 3/10)
      } else if (Math.random() < 0.5) {
        this.currentShot().score = "/"
      } else {
        this.currentShot().score = "X"
      }
    }
  }

  get isLastFrame() { return this.frameNum == 10 }
  get isClosed() { return this.firstShot.knockedAll || this.secondShot.knockedAll }
  get incomplete() { return !this.complete }
  get complete() {
    if (this.firstShot.incomplete) { return false }
    if (!this.isLastFrame) {
      return this.firstShot.knockedAll || this.secondShot.complete
    }
    // 10th frame logic
    // Always a second shot
    if (this.secondShot.incomplete) { return false }
    // If 3rd is complete, then we're done
    if (this.thirdShot.complete) { return true }
    // If 1st is strike, there will be a 3rd, so we're not done
    if (this.firstShot.knockedAll) { return false }
    // If 2nd is closed, there will be a 3rd, so we're not done
    return !this.secondShot.knockedAll
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

  set score(val) { this.standingPins = game.pins.pinsFromInput(val) }

  get incomplete() { return !this.complete }
  get knockedAll() { return this._knocked_all }

  get standingPins() { return game.pins.invert(this.fallenPins) }
  set standingPins(standing_pins) { this.fallenPins = game.pins.invert(standing_pins) }

  get fallenPins() { return this._fallen_pins }
  set fallenPins(fallen_pins) {
    this.complete = true

    let prevShot = this.prevShot()
    if (prevShot) {
      if (prevShot.incomplete) { prevShot.fallenPins = [] }
      if (prevShot.knockedAll) { return this.clear() }
      // Do not allow setting fallen pins to pins that were already fallen in the last shot
      let prev_standing_pins = prevShot.standingPins
      let newlyFallenPins = fallen_pins.filter(pin => prev_standing_pins.includes(pin))
      fallen_pins = [...newlyFallenPins, ...prevShot.fallenPins]
    }
    this._fallen_pins = fallen_pins

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
      if (this.knockedAll) { str = this.frame.firstShot.knockedAll ? "X" : "/" }
    } else if (this.shotNum == 3) {
      if (this.frame.secondShot.knockedAll) {
        if (this.knockedAll) { str = "X" }
      } else if (this.frame.firstShot.knockedAll) {
        if (this.knockedAll) { str = "/" }
      }
    }

    this.element.value = str
    this.remaining_pins_element.value = `[${this.standingPins.join()}]`
    this.checkSplit()

    // Knock next shot pins over if knocked here
    let nextShot = {
      1: () => this.frame.secondShot,
      2: () => this.frame.thirdShot,
    }[this.shotNum]?.call()
    if (!nextShot?.complete) { return } // If it's not filled in, don't do anything
    // Reset knocked pins, which includes filtering the allowed ones.
    if (this.shotNum == 2 && !this.frame.firstShot.knockedAll && !this.knockAll) {
      return nextShot.clear()
    }
    nextShot.fallenPins = nextShot.fallenPins
  }

  checkSplit() {
    if (this.prevShot()) { return }

    let isSplit = game.pins.checkSplit(this.standingPins)
    this.element.closest(".split-holder").classList.toggle("split", isSplit)
  }

  prevShot() {
    if (this.shotNum == 1) { return }
    if (!this.frame.isLastFrame) { return this.frame.firstShot }
    // 10th frame
    if (this.shotNum == 2) {
      return this.frame.firstShot.knockedAll ? null : this.frame.firstShot
    } else if (this.shotNum == 3) {
      return this.frame.secondShot.knockedAll ? null : this.frame.secondShot
    }
  }
}
