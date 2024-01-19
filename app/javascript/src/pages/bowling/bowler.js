import Reactive from "./reactive"
import Frame from "./frame"

export default class Bowler extends Reactive {
  constructor(element, js_id) {
    super(element)
    this.id = js_id || Bowler.genId()

    // prev games? (score, point, card)
    this.elementAccessor("serverId", null, "data-bowler-id", function(value) {
      this.element.querySelector(".bowler-id-field").value = value
    })
    this.elementAccessor("currentFrameNum", null, "data-current-frame")
    this.elementAccessor("absentScore", null, "data-absent-score")
    this.elementAccessor("bowlerNum", null, "data-bowler", function(value) {
      this.element.querySelector(".game-position").value = parseInt(value)-1 // index based
      game.resortBowlers(this)
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
    this.elementAccessor("bowlerGameId", ".bowler-game-id", "value")
    this.elementAccessor("bowlerName", ".bowler-name-field", "value", function(value) {
      this.element.querySelector(".bowler-name .name .display-name").innerText = value
      this.element.querySelector(".bowler-options .details .bowler-options-name").innerText = value
      this.element.querySelector(".bowler-options .bowler-sub-btn")?.setAttribute("data-bowler-name", value)
    })
    this.elementAccessor("absent", ".absent-checkbox", "checked")
    this.elementAccessor("skip", ".skip-checkbox", "checked")
    this.elementAccessor("cardPoint", ".card-point-field", "value")
    this.elementAccessor("currentScore", ".total .score")
    this.elementAccessor("currentScoreHdcp", ".total .hdcp")
    this.elementAccessor("maxScore", ".total .max")

    this.frames = Frame.fullGame(this)
    this.initialized = true
  }

  static genId() { return Math.floor(Math.random() * 16777215).toString(16) }

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

  get shots() {
    let list = []
    this.eachFrame(frame => list.push(...frame.shots.filter(Boolean)))
    return list
  }

  valueOf() { return `bowlers[${this.id}]` }
}
