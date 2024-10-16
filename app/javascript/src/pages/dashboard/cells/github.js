import { Time } from "./_time"
import { Text } from "../_text"
import { Timer } from "./timers"
import { dash_colors, beeps } from "../vars"

(function() {
  var cell = undefined
  let gitGet = async function(url) {
    if (!cell.config.github_apikey) { return }
    let res = await fetch(url, {
      method: "GET",
      headers: {
        accept: "application/vnd.github.v3+json",
        Authorization: "token " + cell.config.github_apikey,
      }
    })

    if (res.ok) {
      return await res.json()
    }
  }
  var gitSearch = async function(filter, repo, prefix) {
    var url = "https://api.github.com/search/issues"
    var uri = url + "?q=" + encodeURIComponent(filter + ` repo:${repo}`)
    let json = await gitGet(uri)
    if (!json) { return }

    return Promise.all(
      json.items.map(async function(issue) {
        let status = undefined
        if (issue.pull_request) {
          let pr = await gitGet(issue.pull_request.url)
          if (pr) {
            if (pr.mergeable_state == "clean") { // All checks good, approved
              status = Text.green("✓")
            } else if (pr.mergeable_state == "blocked") { // Something not ready
              status = Text.red("𐄂")
            } else if (pr.mergeable_state == "unstable") { // Approved, but not all checks passed
              status = Text.red("✓")
            } else {
              let state = pr.mergeable_state
              state = state == "unknown" ? "?" : state
              state = state == "dirty" ? "~" : state
              status = Text.yellow(state)
            }
          }
        }

        return {
          url: (issue.pull_request || issue.issue).html_url,
          status: status,
          id: String(issue.number),
          title: issue.title,
          prefix: prefix,
        }
      })
    )
  }
  let findGit = function(id) {
    id = String(id)
    const sections = ["pending_review", "issues", "prs"]

    for (let section of sections) {
      let found = (cell?.data[section] || []).find(git => git.id === id)
      if (found) { return found }
    }
    return null
  }

  var getLines = async function(cell) {
    let pending_review = []
    pending_review = pending_review.concat(await gitSearch("is:open is:pr review-requested:Rockster160", "oneclaimsolution/ocs-backend", "OCS:B"))
    pending_review = pending_review.concat(await gitSearch("is:open is:pr review-requested:Rockster160", "oneclaimsolution/ocs-frontend", "OCS:F"))

    let issues = []
    issues = issues.concat(await gitSearch("is:open is:issue assignee:Rockster160", "oneclaimsolution/ocs-backend", "OCS:B"))
    issues = issues.concat(await gitSearch("is:open is:issue assignee:Rockster160", "oneclaimsolution/ocs-frontend", "OCS:F"))

    let prs = []
    prs = prs.concat(await gitSearch("is:open is:pr assignee:Rockster160", "oneclaimsolution/ocs-backend", "OCS:B"))
    prs = prs.concat(await gitSearch("is:open is:pr assignee:Rockster160", "oneclaimsolution/ocs-frontend", "OCS:F"))

    cell.data.pending_review = pending_review
    cell.data.issues = issues
    cell.data.prs = prs

    render(cell)
    cell.flash()
  }

  let renderGit = function(git) {
    return [
      git.status,
      Text.rocco(git.id),
      `${git.prefix}:${git.title}`
    ].filter(i => i).join(" ")
  }

  let currentTime = function() {
    const now = new Date()
    const month = now.getMonth() + 1
    const day = now.getDate()
    let hours = now.getHours()
    const minutes = now.getMinutes()
    const ampm = hours >= 12 ? "pm" : "am"
    hours = hours % 12 || 12

    const formattedHours = String(hours).padStart(2, "0")
    const formattedMinutes = String(minutes).padStart(2, "0")

    return `${day}/${month} ${formattedHours}:${formattedMinutes}${ampm}`
  }

  let deployMonitor = function() {
    Monitor.subscribe(cell.config.deploy_uuid, {
      received: function(data) {
        if (!cell.data.monitor_schedule) {
          cell.data.monitor_schedule = setInterval(function() { render(cell) }, 1000)
        }
        cell.flash()
        let json = data.data || {}
        if (json.deploy == "start") {
          let timer = new Timer({ name: currentTime() })
          timer.start.minutes += 2
          timer.start.seconds += 30
          timer.go()
          cell.data.deploy_timers.unshift(timer)
          cell.data.deploy_timers = cell.data.deploy_timers.slice(0, 5)
          localStorage.setItem("deploy_timers", JSON.stringify(cell.data.deploy_timers))
        }
        if (json.deploy == "finish") {
          cell.data.deploy_timers.forEach(item => {
            item.complete(true)
          })
          localStorage.setItem("deploy_timers", JSON.stringify(cell.data.deploy_timers))
          cell.data.monitor_schedule = clearInterval(cell.data.monitor_schedule)
          victoryBeep()
        }
        render(cell)
      },
    })
  }

  let victoryBeep = function() {
    beeps([
      [100, 1000, 0.1, "sine"], // Short and high-pitched
      [150,  800, 0.2, "sine"], // Slightly longer and lower-pitched
      [300, 1200, 0.4, "sine"], // Even longer and higher-pitched
    ])
  }

  var render = function(cell) {
    var lines = []
    if (cell.data.pending_review?.length > 0) {
      lines.push("-- Pending Review:")
      cell.data.pending_review.forEach(function(review) {
        lines.push(renderGit(review))
      })
    }
    if (cell.data.issues?.length > 0) {
      lines.push("-- Issues:")
      cell.data.issues.forEach(function(issue) {
        lines.push(renderGit(issue))
      })
    }
    if (cell.data.prs?.length > 0) {
      lines.push("-- My PRs:")
      cell.data.prs.forEach(function(pr) {
        lines.push(renderGit(pr))
      })
    }
    lines.push("-- Deploys:")
    if (cell.data.deploy_timers?.length) {
      cell.data.deploy_timers.forEach(deploy => {
        lines.push(deploy.render())
      })
    }

    cell.lines(lines)
  }

  cell = Cell.register({
    title: "Github",
    refreshInterval: Time.minutes(5),
    flash: false,
    wrap: false,
    data: {
      deploy_timers: [],
    },
    onload: function() {
      this.data.deploy_timers = Timer.loadFromJSON(JSON.parse(localStorage.getItem("deploy_timers") || "[]"))
      deployMonitor()
    },
    reloader: function() {
      getLines(this)
    },
    command: function(msg) {
      if (/\d+/.test(msg)) {
        let git = findGit(msg)
        if (git) {
          window.open(git.url, "_blank")
        } else {
          var url = "https://github.com/oneclaimsolution/ocs-backend/pull/" + msg
          window.open(url, "_blank")
        }
      }
    }
  })
})()


// | Stats
// │ PRs: 12  Issues: 0  Stars: 1
// │
// │ Open Review Requests
// │ 5813 Remove multiple real gre
// │
// │ My Pull Requests
// │ ✗ 5814 Rn/data/api inbox migr
// │ ✓ 5797 SS-230 Use billing typ
// │
// │ Issues
// │ none
