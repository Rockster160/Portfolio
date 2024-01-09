import LoadingIndicator from "./loading_indicator"

export default class LiveStats {
  constructor() {
  }

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
    this.html = bool || bool === undefined ? LoadingIndicator.html : ""
  }

  static encodeGetUrlParams(url, params) {
    const queryString = Object.keys(params).map(key => {
      const value = params[key]
      if (Array.isArray(value)) {
        return value.map(item => `${encodeURIComponent(key)}[]=${encodeURIComponent(item)}`).join("&")
      } else if (value === undefined || value === null) {
        return
      } else if (typeof value === "object") {
        return this.encodeGetUrlParams("", { [key]: value }).substr(1)
      } else {
        return `${encodeURIComponent(key)}=${encodeURIComponent(value)}`
      }
    }).join("&")

    const separator = url.includes("?") ? "&" : "?"
    return `${url}${separator}${queryString}`
  }

  static async getBowlerData(bowler, pins) {
    let stats = this
    let params = {
      league_id: game.leagueId,
      bowler_id: bowler.serverId,
      pins: pins === undefined ? null : `[${pins.join(",")}]`,
    }

    return await fetch(this.encodeGetUrlParams(this.url, params), {
      method: "GET",
      headers: { "Content-Type": "application/json" },
    }).then(function(res) {
      res.json().then(function(json) {
        if (res.ok) {
          stats.loading(false)
          if (!json.stats.total) { return }

          var nums = json.stats.spare + " / " + json.stats.total
          var ratio = Math.round((json.stats.spare / json.stats.total) * 100)

          stats.html = `${ratio}%</br>${nums}`
        }
      })
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
