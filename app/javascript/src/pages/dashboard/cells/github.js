import { Time } from "./_time"
import { Text } from "../_text"
import { dash_colors } from "../vars"

(function() {
  var cell = undefined
  var gitGet = async function(filter) {
    var url = "https://api.github.com/search/issues"
    var uri = url + "?q=" + encodeURIComponent(filter + " repo:WorkWave/slingshot-web-app")
    var res = await fetch(uri, {
      method: "GET",
      headers: {
        accept: "application/vnd.github.v3+json",
        Authorization: "token " + cell.config.github_apikey,
      }
    })

    if (res.ok) {
      var json = await res.json()
      return json.items.map(function(issue) {
        return {
          url: (issue.pull_request || issue.issue).html_url,
          // status to show if it's open, ready to merge, etc...
          id: issue.number,
          title: issue.title,
        }
      })
    } else {
      return [{
        title: Text.color(dash_colors.red, "[Failed to retrieve]")
      }]
    }
  }

  var getLines = async function(cell) {
    cell.data.pending_review = await gitGet("is:open is:pr review-requested:Rockster160")
    cell.data.issues = await gitGet("is:open is:issue assignee:Rockster160")
    cell.data.prs = await gitGet("is:open is:pr assignee:Rockster160")

    render(cell)
  }

  var render = function(cell) {
    var lines = []
    if (cell.data.pending_review.length > 0) {
      lines.push("-- Pending Review:")
      cell.data.pending_review.forEach(function(review) {
        lines.push([Text.color(dash_colors.green, review.id), review.title].join(" "))
      })
    }
    if (cell.data.issues.length > 0) {
      lines.push("-- Issues:")
      cell.data.issues.forEach(function(issue) {
        lines.push([Text.color(dash_colors.green, issue.id), issue.title].join(" "))
      })
    }
    if (cell.data.prs.length > 0) {
      lines.push("-- My PRs:")
      cell.data.prs.forEach(function(pr) {
        lines.push([Text.color(dash_colors.green, pr.id), pr.title].join(" "))
      })
    }

    cell.lines(lines)
    cell.flash()
  }

  cell = Cell.register({
    title: "Github",
    refreshInterval: Time.minutes(5),
    flash: false,
    wrap: false,
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
