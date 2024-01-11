import Reactive from "./reactive"
import Scoring from "./scoring"
import applyFrameModifiers from "./frame_modifiers"
import { trigger } from "./events"

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
    this._score = undefined

    this.firstShot = new Shot(this, 1)
    this.secondShot = new Shot(this, 2)
    if (frameNum == 10) {
      this.thirdShot = new Shot(this, 3)
    }

    this.elementAccessor("strikePoint", ".strike-point", "value", function(val) {
      document.querySelector(".pocket-toggle").classList.toggle("active", val == "pocket")
      document.querySelector(".brooklyn-toggle").classList.toggle("active", val == "brooklyn")
    })
  }

  get display() { return this._score }
  set display(val) {
    this._score = val
    this.element.querySelector(".score").innerText = val
  }

  eachShot(callback) { this.shots.forEach(item => item ? callback(item) : null) }

  updateScores(skip_bowler) {
    if (!game.initialized) { return }
    if (!skip_bowler) { Scoring.updateBowler(this.bowler) }
    applyFrameModifiers(this)
  }

  resetStrikePoint() { this.strikePoint = this.strikePoint }
  clear() {
    this.eachShot(shot => shot.clear(true))
  }

  get siblings() {
    return game.bowlers.map(bowler => bowler && bowler.frames[this.frameNum]).filter(Boolean) || []
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
    // let avg = this.bowler?.average || 200
    let ratio = (rate) => Math.random() < rate
    while (!this.complete) {
      if (ratio(1/1000)) { // 200avg gutters 1/1000 throws
        this.currentShot().score = "-"
      } else if (ratio(3/10)) { // 200avg opens 3 frames a game
        // Keep 3/10 pins, on average
        this.currentShot().standingPins = game.pins.allPins.filter(pinNum => ratio(3/10))
      } else if (ratio(1/2)) { // 200avg spare/strikes half the time
        this.currentShot().score = "/"
      } else { // Fallback after the spare - default to strike
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
  get started() { return this.shots.some(shot => shot?.complete) }

  valueOf() {
    return `bowlers[${this.bowler.serverId}][${this.frameNum}]`
  }
}

class Shot extends Reactive {
  constructor(frame, shot_num) {
    super(frame.element.querySelector(`.shot[data-shot-idx="${shot_num-1}"]`))
    this.remaining_pins_element = frame.element.querySelector(`.fallen-pins[data-shot-idx="${shot_num-1}"]`)
    this.shotNum = shot_num
    this.frame = frame

    this.clear(false)
  }

  clear(reset) {
    this.complete = false
    this.value = undefined
    this.pinFallCount = undefined
    this._fallen_pins = undefined
    this._knocked_all = false
    if (reset) {
      this.element.value = ""
      this.remaining_pins_element.value = ""
    } else {
      if (this.remaining_pins_element.value) {
        this.score = this.remaining_pins_element.value
      }
    }
    this.nextShot()?.clear(reset)
    this.frame.updateScores()
  }

  get score() { return this.value || "" }
  set score(val) { this.standingPins = game.pins.pinsFromInput(val) }

  get incomplete() { return !this.complete }
  get knockedAll() { return this._knocked_all }

  get standingPins() {
    let standing = game.pins.invert(this.fallenPins)

    let prevShot = this.prevShot()
    if (prevShot) {
      let prev_fallen_pins = prevShot.fallenPins
      standing = standing.filter(pin => !prev_fallen_pins.includes(pin))
    }

    return standing
  }
  set standingPins(standing_pins) { this.fallenPins = game.pins.invert(standing_pins) }

  get fallenPins() { return this._fallen_pins || [] }
  set fallenPins(fallen_pins) {
    this.complete = true

    let prevShot = this.prevShot()
    if (prevShot) {
      if (prevShot.incomplete) { prevShot.fallenPins = [] }
      if (prevShot.knockedAll) { return this.clear(true) }
      // Do not allow setting fallen pins to pins that were already fallen in the last shot
      let prev_standing_pins = prevShot.standingPins
      let newlyFallenPins = fallen_pins.filter(pin => prev_standing_pins.includes(pin))
      fallen_pins = [...newlyFallenPins, ...prevShot.fallenPins]
    }
    if (fallen_pins == this._fallen_pins) { return }
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

    this.value = str
    this.element.value = this.value
    this.remaining_pins_element.value = `[${this.standingPins.join()}]`
    this.checkSplit()
    this.frame.updateScores()
    trigger("shot:change", { shot: this })

    // Knock next shot pins over if editing
    let nextShot = this.nextShot()
    if (!nextShot?.complete) { return } // If it's not filled in, don't do anything
    // First and second are open, so no 3rd frame. Clear it and move to next bowler.
    if (this.shotNum == 2 && !this.frame.firstShot.knockedAll && !this.knockAll) {
      return nextShot.clear(true)
    }
    // Reset knocked pins, which includes filtering the allowed ones.
    nextShot.fallenPins = nextShot.fallenPins
  }

  checkSplit() {
    if (this.prevShot()) { return }

    let isSplit = game.pins.checkSplit(this.standingPins)
    this.element.closest(".split-holder").classList.toggle("split", isSplit)
  }

  nextShot() {
    return {
      1: () => this.frame.secondShot,
      2: () => this.frame.thirdShot,
    }[this.shotNum]?.call()
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

  valueOf() {
    return `bowlers[${this.bowler.serverId}][${this.frame.frameNum}][${this.shotNum}]`
  }
}
