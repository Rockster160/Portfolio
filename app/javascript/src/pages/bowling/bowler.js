import Reactive from "./reactive"
import Frame from "./frame"

export default class Bowler extends Reactive {
  constructor(element) {
    super(element)
    this.serverId = parseInt(element.getAttribute("data-bowler-id"))

    // prev games? (score, point, card)
    this.elementAccessor("currentFrame", null, "data-current-frame")
    this.elementAccessor("absentScore", null, "data-absent-score")
    this.elementAccessor("bowlerNum", null, "data-bowler", function(value) {
      this.element.querySelector(".game-position").value = value
      // Also need to reorder game.bowlers
      // Also need to actually reorder the bowler rows rather than just updating the position
    })
    this.elementAccessor("hdcp", ".bowler-handicap", "value", function(value) {
      this.element.querySelectorAll(".hdcp-val").forEach(item => item.innerText = value)
      this.element.querySelectorAll(".hdcp").forEach(item => item.innerText = value)
      this.element.querySelectorAll(".hdcp").forEach(item => item.setAttribute("data-base", value))
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
    this.elementAccessor("currentScore", ".total .score")
    this.elementAccessor("maxScore", ".total .max")

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

  eachFrame(callback) { this.frames.forEach(item => item ? callback(item) : null) }

  get active() { return !this.absent && !this.skip }

  get num() { return parseInt(this.bowlerNum) }
  set num(val) { return this.bowlerNum = val }
}
