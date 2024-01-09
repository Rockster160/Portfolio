export default class FrameNavigation {
  static _current_frame = undefined
  static _current_shot = undefined

  static get currentShot() {
    if (this._current_shot) { return this._current_shot }
    return this._current_shot = this.currentFrame?.currentShot()
  }
  static set currentShot(shot) {
    game.pinTimer.clear(true)
    this._current_shot = shot
    this._current_frame = shot?.frame
    document.querySelectorAll(".shot.current").forEach(item => item.classList.remove("current"))
    if (!shot) {
      game.pins.fallenBefore = []
      game.defaultPinStanding ? game.pins.standAll() : game.pins.knockAll()
      return
    }

    shot.element.classList.add("current")
    game.pins.noBroadcast(() => {
      // Update fallen pins and strike point
      shot.frame.resetStrikePoint()
      let prevShot = shot.prevShot()
      game.pins.fallenBefore = prevShot?.fallenPins || []
      if (shot.complete) {
        game.pins.standing = shot.standingPins
      } else {
        if (prevShot) { // 2nd shot always sets pins to standing for usability
          game.pins.standAll()
        } else {
          game.defaultPinStanding ? game.pins.standAll() : game.pins.knockAll()
        }
      }
    })
    document.dispatchEvent(new CustomEvent("frame:move", { bubbles: true }))
  }

  static get currentFrame() { return this._current_frame }
  static set currentFrame(frame) { this.currentShot = frame?.currentShot() }

  static earliestUnfinishedFrame() {
    for (let i=1; i<=10; i++) {
      for (const bowler of game.bowlers) {
        if (bowler?.active) {
          let frame = bowler.frames[i]
          if (frame.incomplete) { return frame }
        }
      }
    }
  }

  static nextShot() {
    if (this.currentFrame?.incomplete) {
      this.currentFrame = this.currentFrame // Reset current frame, which will go to incomplete shot
    } else {
      this.currentFrame = this.earliestUnfinishedFrame()
    }
  }
}
