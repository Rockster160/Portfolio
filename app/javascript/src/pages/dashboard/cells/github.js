import { Time } from "./_time"
import { Text } from "../_text"
import { Timer } from "./timers"
import { dash_colors } from "../vars"

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
  var gitSearch = async function(filter) {
    var url = "https://api.github.com/search/issues"
    var uri = url + "?q=" + encodeURIComponent(filter + " repo:WorkWave/slingshot-web-app")
    let json = await gitGet(uri)
    if (!json) { return }

    return Promise.all(
      json.items.map(async function(issue) {
        let status = undefined
        if (issue.pull_request) {
          let pr = await gitGet(issue.pull_request.url)
          if (pr) {
            if (pr.mergeable_state == "clean") { // All checks good, approved
              status = Text.color(dash_colors.green, "✓")
            } else if (pr.mergeable_state == "blocked") { // Something not ready
              status = Text.color(dash_colors.red, "𐄂")
            } else if (pr.mergeable_state == "unstable") { // Approved, but not all checks passed
              status = Text.color(dash_colors.orange, "✓")
            } else {
              status = Text.color(dash_colors.orange, "[" + pr.mergeable_state + "]")
            }
          }
        }

        return {
          url: (issue.pull_request || issue.issue).html_url,
          status: status,
          id: issue.number,
          title: issue.title,
        }
      })
    )
  }

  var getLines = async function(cell) {
    cell.data.pending_review = await gitSearch("is:open is:pr review-requested:Rockster160")
    cell.data.issues = await gitSearch("is:open is:issue assignee:Rockster160")
    cell.data.prs = await gitSearch("is:open is:pr assignee:Rockster160")

    render(cell)
    cell.flash()
  }

  let renderLine = function(status, id, title) {
    return [
      status,
      Text.color(dash_colors.green, id),
      title
    ].filter(i => i).join(" ")
  }

  let currentTime = function() {
    const now = new Date()
    let hours = now.getHours()
    const minutes = now.getMinutes()
    const ampm = hours >= 12 ? "pm" : "am"
    hours = hours % 12 || 12

    const formattedHours = String(hours).padStart(2, "0")
    const formattedMinutes = String(minutes).padStart(2, "0")

    return `${formattedHours}:${formattedMinutes}${ampm}`
  }

  let deployMonitor = function() {
    setInterval(function() { render(cell) }, 1000)
    Monitor.subscribe("e7a6570c-3d6d-434b-bcd6-568a41fb6b02", "deploy", {
      received: function(data) {
        cell.flash()
        let json = data.result ? JSON.parse(data.result) : {}
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
        }
        render(cell)
      },
    })
  }

  var render = function(cell) {
    var lines = []
    if (cell.data.pending_review?.length > 0) {
      lines.push("-- Pending Review:")
      cell.data.pending_review.forEach(function(review) {
        lines.push(renderLine(review.status, review.id, review.title))
      })
    }
    if (cell.data.issues?.length > 0) {
      lines.push("-- Issues:")
      cell.data.issues.forEach(function(issue) {
        lines.push(renderLine(issue.status, issue.id, issue.title))
      })
    }
    if (cell.data.prs?.length > 0) {
      lines.push("-- My PRs:")
      cell.data.prs.forEach(function(pr) {
        lines.push(renderLine(pr.status, pr.id, pr.title))
      })
    }
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
      deployMonitor()
      this.data.deploy_timers = Timer.loadFromJSON(JSON.parse(localStorage.getItem("deploy_timers") || "[]"))
    },
    reloader: function() {
      getLines(this)
    },
    command: function(msg) {
      if (/\w+\-\d+/.test(msg)) {
        var jira_id = msg.match(/\w+\-\d+/)
        jira_id = jira_id ? jira_id[0] : ""
        var url = "https://workwave.atlassian.net/browse/" + jira_id
        window.open(url, "_blank")
      } else if (/\d+/.test(msg)) {
        var url = "https://github.com/WorkWave/slingshot-web-app/pull/" + msg
        window.open(url, "_blank")
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
