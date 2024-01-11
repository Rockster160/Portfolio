import Rest from "./rest"

export default class LiveStats {
  static get element() {
    return document.querySelector(".stats-holder")
  }

  static get url() {
    return this.element.getAttribute("data-stats-url")
  }

  static set html(val) {
    if (!this.element) { return }

    this.element.innerHTML = val || ""
  }

  static loading(bool) {
    this.html = bool || bool === undefined ? "<i class=\"fa fa-spinner fa-spin\"></i>" : ""
  }

  static async getBowlerData(bowler, pins) {
    let stats = this
    let params = {
      league_id: game.leagueId,
      bowler_id: bowler.serverId,
      pins: pins === undefined ? null : `[${pins.join(",")}]`,
    }

    Rest.get(this.url, params, (json) => {
      this.loading(false)
      if (!json.stats.total) { return }

      var nums = json.stats.spare + " / " + json.stats.total
      var ratio = Math.round((json.stats.spare / json.stats.total) * 100)

      this.html = `${ratio}%</br>${nums}`
    })
  }

  static async generate() {
    this.loading(false)

    if (!game?.pinMode || !game?.checkStats) { return }

    let shot = game.currentShot
    let frame = shot?.frame
    let bowler = frame?.bowler
    let bowlerId = bowler?.serverId

    if (!bowlerId) { return }

    this.loading(true)

    let prevShot = shot.prevShot()
    this.getBowlerData(bowler, prevShot?.standingPins)
  }
}
