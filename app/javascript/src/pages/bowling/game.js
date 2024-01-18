import Reactive from "./reactive"
import Bowler from "./bowler"
import Pins from "./pins"
import PinTimer from "./pin_timer"
import Scoring from "./scoring"
import FrameNavigation from "./frame_navigation"
import Rest from "./rest"
import { trigger, lastSelector } from "./events"

export default class Game extends Reactive {
  constructor(element) {
    super(element)
    window.game = this

    this.editing_game = !!document.querySelector(".ctr-bowling_games.act-edit")
    this.bool("saved", function(val) {
      console.log(val ? "Saved!" : "Changes made...");
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
      if (!value && !this.skipSaveAfterEdit) { this.saveScores() }
      this.skipSaveAfterEdit = false
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

  get finishBtn() { return this.element.querySelector(".bowling-form-btn") }

  addBowler(data) {
    let bowler_id = Bowler.genId()
    let template = document.querySelector("#bowling-game-template")

    let templateHTML = template.innerHTML.replace(/{{id}}/g, bowler_id)
    let tempTemplate = document.createElement("template")
    tempTemplate.innerHTML = templateHTML

    let clone = tempTemplate.content.cloneNode(true)
    let placeholder = this.element.querySelector(".bowler-placeholder")
    this.element.insertBefore(clone, placeholder)
    let element = lastSelector(document, ".bowler")
    let bowler = new Bowler(element, bowler_id)
    this.bowlers.push(bowler)

    for (const [key, value] of Object.entries(data)) {
      if (key != "bowlerNum") {
        if (value) { bowler[key] = value }
      }
    }
    bowler.bowlerNum = data.bowlerNum || this.bowlers.length // Triggers resort and save
    return bowler
  }
  removeBowler(bowler) {
    if (bowler.serverId) {
      Rest.delete(this.element.action + `/bowler/${bowler.serverId}`, { game_num: game.gameNum }).then(res => {
        this.bowlers = this.bowlers.filter(other => !other || other.id != bowler.id)
        bowler.element.remove()
        this.resetBowlers()
      })
    } else {
      this.bowlers = this.bowlers.filter(other => !other || other.id != bowler.id)
      bowler.element.remove()
      this.resetBowlers()
    }
  }

  bowlerFrom(ele) {
    return this.bowlers[parseInt(ele.closest(".bowler").getAttribute("data-bowler"))]
  }

  resortBowlers(bowler) {
    // Only re-order and organize elements once - this can potentially call itself
    if (this.sorting) { return }
    // Avoid unnecessary sorting
    if (bowler == game.bowlers[bowler.bowlerNum]) { return }
    this.sorting = true
    // Swap conflicts
    let oldNum = game.bowlers.indexOf(bowler)
    this.eachBowler(other => {
      if (bowler != other && bowler.bowlerNum == other.bowlerNum) { other.bowlerNum = oldNum }
    })
    this.resetBowlers()
    this.sorting = false
  }

  resetBowlers() {
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

    Scoring.updateTotals()
    this.saveScores()
  }

  syncServerBowlers(data) {
    game.eachBowler(bowler => {
      data?.bowlers?.forEach(bowler_data => {
        if (!bowler.serverId && bowler_data.name == bowler.bowlerName) {
          bowler.serverId = bowler_data.id
          console.log(`Set ${bowler.bowlerName} to ${bowler.serverId}`);
        }
        if (bowler.serverId == bowler_data.id) {
          bowler.bowlerGameId = bowler_data.bowler_game_id
        }
      })
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
    this.saveScores()
    this.finishBtn.classList.remove("hidden")
  }

  saveScores() { game.save("PATCH") }
  save(method, callback) {
    if (!this.initialized) { return }
    if (method && typeof method === "function") { [callback, method] = [method, null] }
    let form = this.element

    Rest.submit(form, { method: method }).then(json => {
      console.log(json);
      if (json) {
        this.syncServerBowlers(json)
        this.saved = true
        if (callback && typeof callback === "function") { callback(json) }
      }
    })
  }

  nextGame() {
    if (!this.saved) {
      if (!confirm("The game is has unsaved changes. Are you sure you want to continue?")) {
        return false
      }
    }
    if (!this.bowlers.find(bowler => bowler?.cardPoint)) {
      if (!confirm("You did not enter a winner for cards. Are you sure you want to continue?")) {
        return false
      }
    }
    this.finishBtn.value = "Saving..."
    this.save(function(data) {
      window.location.href = data.redirect
    })
    // TODO: Detect failed submission somehow
    // this.finishBtn.value = "Try Again"
  }

  fillRandomUntil(end_frame, fill_with) {
    end_frame = end_frame || 10
    this.eachBowler(bowler => {
      if (bowler.active) {
        bowler.eachFrame(frame => {
          if (frame.frameNum <= end_frame) {
            if (fill_with) {
              frame.firstShot.score = fill_with
            } else {
              frame.fillRandom()
            }
          }
        })
      }
    })
    this.nextShot()
  }

  clearShot() {
    FrameNavigation.currentShot.clear(true)
    FrameNavigation.currentShot = FrameNavigation.currentShot // Reset pins by resetting shot
  }

  showStats() {
    Scoring.generateStats()
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
