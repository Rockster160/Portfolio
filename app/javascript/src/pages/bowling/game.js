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
    this.bool("saved", function(val) {
      console.log(val ? "Saved!" : "Not saved...");
    })

    this._game_num = params.game ? parseInt(params.game) : 1
    this.elementAccessor("leagueId", "#game_league_id", "value")
    this.elementAccessor("setId", "#game_set_id", "value")

    this.elementAccessor("laneTalkCenterUUID", ".league-data", "data-lanetalk-center-id")
    this.elementAccessor("laneTalkApiKey", ".league-data", "data-lanetalk-key")

    this.elementAccessor("lane", ".lane-input", "value", function(val) {
      this.saveScores()
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
      if (!value) { this.saveScores() }
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

  bowlerFrom(ele) {
    return this.bowlers[parseInt(ele.closest(".bowler").getAttribute("data-bowler"))]
  }

  resortBowlers(bowler) {
    // Avoid unnecessary sorting
    if (bowler == game.bowlers[bowler.bowlerNum]) { return }
    // Only re-order and organize elements once
    if (this.sorting) { return }
    this.sorting = true
    // Swap conflicts
    let oldNum = game.bowlers.indexOf(bowler)
    this.eachBowler(other => {
      if (bowler != other && bowler.bowlerNum == other.bowlerNum) { other.bowlerNum = oldNum }
    })
    // Re-sort
    this.bowlers.sort((a, b) => {
      if (a === null) { return -1 }
      if (b === null) { return 1 }
      return a.bowlerNum - b.bowlerNum
    })
    // Reset Nums to proper idx
    this.bowlers.forEach((other, idx) => {
      if (other && other.bowlerNum != idx) { other.bowlerNum = idx }
    })
    // Move elements
    this.bowlers.toReversed().forEach(other => {
      if (other) { this.element.insertBefore(other.element, this.element.firstChild) }
    })
    this.sorting = false
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
    // $(".bowling-form-btn").removeClass("hidden")
  }

  fillRandomUntil(end_frame, fill_with) {
    end_frame = end_frame || 10
    this.eachBowler(bowler => {
      bowler.eachFrame(frame => {
        if (frame.frameNum <= end_frame) {
          if (fill_with) {
            frame.firstShot.score = fill_with
          } else {
            frame.fillRandom()
          }
        }
      })
    })
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
      game.saved = true
    })
  }

  earliestFrame() {
    return FrameNavigation.earliestUnfinishedFrame()
  }

  nextShot(save_current) {
    if (save_current) { trigger("pin:change") }

    FrameNavigation.nextShot()
    if (!this.currentShot) { this.finish() }
  }
}
