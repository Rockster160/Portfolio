import Reactive from "./reactive"
import Frame from "./frame"

export default class Bowler extends Reactive {
  constructor(element) {
    super(element)
    this.server_id = parseInt(element.getAttribute("data-bowler-id"))

    // prev games? (score, point, card)
    this.elementAccessor("currentFrame", null, "data-current-frame")
    this.elementAccessor("absentScore", null, "data-absent-score")
    this.elementAccessor("bowlerNum", null, "data-bowler", function(value) {
      this.element.querySelector(".game-position").value = value
    })
    this.elementAccessor("hdcp", ".bowler-handicap", "value", function(value) {
      this.element.querySelectorAll(".hdcp-val").forEach(item => item.innerText = value)
    })
    this.elementAccessor("avg", ".bowler-average", "value", function(value) {
      this.element.querySelectorAll(".avg-val").forEach(item => item.innerText = value)
    })
    this.elementAccessor("usbcName", ".usbc-name")
    this.elementAccessor("usbcNumber", ".usbc-number")
    this.elementAccessor("bowlerName", ".bowler-name-field", "value", function(value) {
      this.element.querySelector(".bowler-name .name .display-name").innerText = value
      this.element.querySelector(".bowler-options .details .bowler-options-name").innerText = value
    })
    this.elementAccessor("absent", ".absent-checkbox", "checked")
    this.elementAccessor("skip", ".skip-checkbox", "checked")
    this.elementAccessor("cardPoint", ".card-point-field", "value")
    // this.elementAccessor("currentScore", ".usbc-name")
    // this.elementAccessor("currentScore", function(value) {
    //   this.element.querySelector(".total .score").innerText = value
    // })
    // this.elementAccessor("maxScore", function(value) {
    //   this.element.querySelector(".total .score").innerText = value
    //   , ".total .max"
    // })

    this.frames = Frame.fullGame(this)
  }

  get currentScore() { return this._current_score }
  set currentScore(value) {
    console.log("currentScore", value);
    this._current_score = value
    this.element.querySelector(".total .score").value = value
  }
  get maxScore() { return this._max_score }
  set maxScore(value) {
    console.log("maxScore", value);
    this._max_score = value
    this.element.querySelector(".total .max").innerText = value
  }
  // TODO: Need to update score on frame delete and change as well
  // Last frame scoring doesn't seem quite right.
  //   When setting "9" as the first score, the max score changes even after striking out
  //   Just seems wonky in general - check it out.

  static get() {
    let bowlers = Array.from(document.querySelectorAll(".bowler")).map(bowler => new Bowler(bowler))
    bowlers.unshift(null) // Add empty space at the beginning of the array to align num to idx
    return bowlers
  }

  static byName = function(name) {
    let clean = name.trim().toLowerCase()
    return Bowler.bowlers.find(bowler => bowler && bowler.bowlerName.trim().toLowerCase() == clean)
  }

  get active() { return !this.absent && !this.skip }
}
