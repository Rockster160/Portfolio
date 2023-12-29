import Reactive from "./reactive"
import BowlingCalculator from "./calculator"
import Pins from "./pins"
import PinTimer from "./pin_timer"

export default class Game extends Reactive {
  constructor(element) {
    super(element)
    this.element = element

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
    this.bool("pinAll", function(value) {
      this.element.querySelector(".pin-all-toggle").classList.toggle("fall", value)
      this.pins.toggleAll(!value)
    })

    let storedVal = sessionStorage.getItem("useLaneTalk") // !edit_page &&
    let useLaneTalk = storedVal !== null ? storedVal == "true" : true
    this.laneTalk = useLaneTalk
    this.editBowler = false

    this.pinMode = true
    this.pinWrapper = new Pins()
    this.pinTimer = new PinTimer()

    this.pinAll = true

    this.calculator = BowlingCalculator

    // calculate score
    // able to be given a string like "X 9/ 5"...
    //   Also GET a string of those scores
    // get score
    // get handicap (bowler)
  }

  get gameNum() { return this._game_num }
  set gameNum(num) {
    this._game_num = num
    this.bowlers.forEach(bowler => {
      bowler.element.querySelector(".bowler-game-number").value = num
    })
  }

  get pins() { return this.pinWrapper }
  set pins(standing) {
    this.pinWrapper.standing = standing
  }

  nextFrame() {
    console.log("Next Frame");
  }
}
