import Reactive from "./reactive"
import Bowler from "./bowler"
import Pins from "./pins"
import PinTimer from "./pin_timer"
import Scoring from "./scoring"
import FrameNavigation from "./frame_navigation"

export default class Game extends Reactive {
  constructor(element) {
    super(element)

    this.editing_game = !!document.querySelector(".ctr-bowling_games.act-edit")

    this._game_num = params.game ? parseInt(params.game) : 1
    this.accessor("leagueId", "#game_league_id", "value")
    this.accessor("setId", "#game_set_id", "value")

    this.accessor("laneTalkCenterUUID", ".league-data", "data-lanetalk-center-id")
    this.accessor("laneTalkApiKey", ".league-data", "data-lanetalk-key")

    this.accessor("lane", ".lane-input", "value")

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

    this.pinMode = true
    this.pins = new Pins()
    this.pinTimer = new PinTimer()

    this.defaultPinStanding = false

    this.bowlers = Bowler.get()
    // this.scoring = new Scoring(this.bowlers)

    // calculate score
    // able to be given a string like "X 9/ 5"...
    //   Also GET a string of those scores
    // get score
    // get handicap (bowler)
    this.filled = false
  }

  get strikePoint() { return FrameNavigation.currentFrame.strikePoint }
  set strikePoint(strike_point) { FrameNavigation.currentFrame.strikePoint = strike_point }

  get currentFrame() { return FrameNavigation.currentFrame }
  get currentShot() { return FrameNavigation.currentShot }
  set currentShot(shot) { return FrameNavigation.currentShot = shot }

  get gameNum() { return this._game_num }
  set gameNum(num) {
    this._game_num = num
    this.bowlers.forEach(bowler => {
      if (bowler) { bowler.element.querySelector(".bowler-game-number").value = num }
    })
  }

  start() {
    this.pinTimer.addTo(".timer-toggle")
    // set absent/skipped bowler
    this.nextShot() // Set the first frame
  }
  finish() {
    console.log("Game complete");
    // Show End Game button
  }

  nextShot(save_current) {
    if (save_current) {
      this.currentShot?.element?.dispatchEvent(new CustomEvent("pin:change", { bubbles: true }))
    }

    FrameNavigation.nextShot()
    this.pinTimer.clear()
    if (!this.currentShot) { this.finish() }
  }
}
