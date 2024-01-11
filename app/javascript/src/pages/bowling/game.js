import Reactive from "./reactive"
import Bowler from "./bowler"
import Pins from "./pins"
import PinTimer from "./pin_timer"
import Scoring from "./scoring"
import FrameNavigation from "./frame_navigation"
import { trigger } from "./events"

export default class Game extends Reactive {
  constructor(element) {
    super(element)
    window.game = this

    this.editing_game = !!document.querySelector(".ctr-bowling_games.act-edit")

    this._game_num = params.game ? parseInt(params.game) : 1
    this.elementAccessor("leagueId", "#game_league_id", "value")
    this.elementAccessor("setId", "#game_set_id", "value")

    this.elementAccessor("laneTalkCenterUUID", ".league-data", "data-lanetalk-center-id")
    this.elementAccessor("laneTalkApiKey", ".league-data", "data-lanetalk-key")

    this.elementAccessor("lane", ".lane-input", "value", function(val) {
      console.log(`Setting Lane to ${val}`)
    })

    this.bool("crossLane")
    this.bool("pinMode", function(value) {
      this.element.querySelectorAll("[data-pins-show=show]").forEach(item => {
        item.classList.toggle("hidden", !value)
      })
      this.element.querySelectorAll("[data-pins-show=hide]").forEach(item => {
        item.classList.toggle("hidden", value)
      })
    })
    this.bool("laneTalk", function(value) {
      this.element.querySelector(".lanetalk-toggle").classList.toggle("active", value)
      sessionStorage.setItem("useLaneTalk", value)
    })
    this.bool("editBowler", function(value) {
      document.querySelectorAll("[data-edit=show]").forEach(item => item.classList.toggle("hidden", !value))
      document.querySelectorAll("[data-edit=hide]").forEach(item => item.classList.toggle("hidden", value))
    })
    this.bool("defaultPinStanding", function(value) {
      this.element.querySelector(".pin-all-toggle").classList.toggle("fall", !value)
      this.pins.noBroadcast(() => this.pins.toggleAll(value))
    })

    let storedVal = sessionStorage.getItem("useLaneTalk") // !edit_page &&
    let useLaneTalk = storedVal !== null ? storedVal == "true" : true
    this.laneTalk = useLaneTalk
    this.editBowler = false

    this.checkStats = true
    this.pinMode = true
    this.pins = new Pins()
    this.pinTimer = new PinTimer()

    this.defaultPinStanding = false

    this.bowlers = Bowler.get()

    this.initialized = true
  }

  get strikePoint() { return FrameNavigation.currentFrame.strikePoint }
  set strikePoint(strike_point) { FrameNavigation.currentFrame.strikePoint = strike_point }

  get currentBowler() { return FrameNavigation.currentBowler }
  get currentFrame() { return FrameNavigation.currentFrame }
  get currentShot() { return FrameNavigation.currentShot }
  set currentShot(shot) { return FrameNavigation.currentShot = shot }

  get gameNum() { return this._game_num }
  set gameNum(num) {
    this._game_num = num
    this.eachBowler(bowler => {
      if (bowler) { bowler.element.querySelector(".bowler-game-number").value = num }
    })
  }

  eachBowler(callback) { this.bowlers.forEach(item => item ? callback(item) : null) }

  start() {
    this.pinTimer.addTo(".timer-toggle")
    // set absent/skipped bowler
    this.nextShot() // Set the first frame
    this.eachBowler(bowler => {
      bowler.eachFrame(frame => {
        if (frame.started) { frame.updateScores(true) }
      })
      Scoring.updateBowler(bowler)
    })
  }
  finish() {
    console.log("Game complete");
    // Show End Game button
  }

  clearShot() {
    FrameNavigation.currentShot.clear(true)
    FrameNavigation.currentShot = FrameNavigation.currentShot // Reset pins by resetting shot
  }

  showStats() {
    Scoring.generateStats()
  }

  saveScores() {
    Scoring.submit(() => {
      console.log("Updated!");
    })
  }

  nextShot(save_current) {
    if (save_current) { trigger("pin:change") }

    FrameNavigation.nextShot()
    if (!this.currentShot) { this.finish() }
  }
}
