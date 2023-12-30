export default class FrameNavigation {
  static _current_frame = undefined
  static _current_shot = undefined

  static get currentShot() {
    if (this._current_shot) { return this._current_shot }
    return this._current_shot = this.currentFrame.currentShot()
  }
  static set currentShot(shot) {
    this._current_shot = shot
    this._current_frame = shot.frame
    document.querySelectorAll(".shot.current").forEach(item => item.classList.remove("current"))
    // getPreviousShot
    //   based on shot num, -1 if 2nd or if 10th logic
    // add .fallen-before to PrevShot pins
    this.currentShot.element.classList.add("current")
  }

  static get currentFrame() { return this._current_frame }
  static set currentFrame(frame) { this.currentShot = frame.currentShot() }

  static earliestUnfinishedFrame() {
    for (let i=1; i<=10; i++) {
      for (const bowler of game.bowlers) {
        let frame = bowler.frames[i]
        if (!frame.finished()) { return frame }
      }
    }
  }

  static nextShot() {
    game.pins.noBroadcast(() => {
      this.currentFrame = this.earliestUnfinishedFrame()
      let shot = this.currentShot
      let prevShot = shot.prevShot()

      game.pins.fallenBefore = prevShot?.fallenPins || []
      if (shot.complete) {
        game.pins.standing = shot.standingPins
      } else {
        if (prevShot) { // Easier to select the newly knocked pins, which is reversing logic
          game.pins.standAll()
        } else {
          game.defaultPinStanding ? game.pins.standAll() : game.pins.knockAll()
        }
      }
    })
  }
}
