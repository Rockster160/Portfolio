import Reactive from "./reactive"
import Frame from "./frame"

export default class Bowler extends Reactive {
  constructor(element) {
    super(element)
    this.server_id = parseInt(element.getAttribute("data-bowler-id"))

    // prev games? (score, point, card)
    this.accessor("currentFrame", null, "data-current-frame")
    this.accessor("absentScore", null, "data-absent-score")
    this.accessor("bowlerNum", null, "data-bowler", function(value) {
      this.element.querySelector(".game-position").value = value
    })
    this.accessor("hdcp", ".bowler-handicap", "value", function(value) {
      this.element.querySelectorAll(".hdcp-val").forEach(item => item.innerText = value)
    })
    this.accessor("avg", ".bowler-average", "value", function(value) {
      this.element.querySelectorAll(".avg-val").forEach(item => item.innerText = value)
    })
    this.accessor("usbcName", ".usbc-name")
    this.accessor("usbcNumber", ".usbc-number")
    this.accessor("bowlerName", ".bowler-name-field", "value", function(value) {
      this.element.querySelector(".bowler-name .name .display-name").innerText = value
      this.element.querySelector(".bowler-options .details .bowler-options-name").innerText = value
    })
    this.accessor("absent", ".absent-checkbox", "checked")
    this.accessor("skip", ".skip-checkbox", "checked")
    this.accessor("cardPoint", ".card-point-field", "value")

    this.frames = Frame.fullGame(this)
  }

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
