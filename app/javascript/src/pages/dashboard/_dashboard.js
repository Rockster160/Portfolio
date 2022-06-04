import { Text } from "./_text"

$(document).ready(function() {
  if ($(".ctr-dashboard").length == 0) { return }
  var dashboard_history = [], history_idx = -1, history_hold = ""
  var autocomplete_on = false
  var $omnibar = $(".dashboard-omnibar input")

  function omniRaw() { return $omnibar.val() }
  function omniSelector() {
    var selector = omniRaw().match(/(?:\:)(\w|\-)+/i)
    return selector ? selector[0] : ""
  }
  function omniVal() {
    return omniRaw().replace(/\:(\w|\-)+\s*/i, "")
  }
  function autocompleteOptions() {
    var cell = Cell.from_ele($(".dash-cell.active"))
    if (cell) {
      return cell.autocomplete(omniVal())
    } else {
      var cell_names = cells.map(function(cell) { return ":" + cell.name + " " })
      return Text.filterOrder(omniVal(), cell_names)
    }
  }
  function resetDropup() {
    $(".drop-item").remove()
    if (autocomplete_on) {
      autocompleteOptions().forEach(function(option) {
        var item_name = $("<span>", { class: "name" }).text(option)
        var drop_item = $("<div>", { class: "drop-item" }).append(item_name)
        // var summary = $("<div>", { class: "summary" }).text(entry.summary)
        // if (entry.summary && entry.summary.length > 0) { drop_item.append(summary) }

        $(".dashboard-omnibar-autocomplete").append(drop_item)
      })
      if ($(".drop-item.selected").length == 0) { $(".drop-item").first().addClass("selected") }
    }
  }

  function autocompleteUpKey() {
    if ($(".drop-item.selected").length > 0) {
      // next because CSS reverses order
      var next = $(".drop-item.selected").next()
      if (next) {
        $(".drop-item").removeClass("selected")
        next.addClass("selected")
      }
    } else {
      // first because CSS reverses order
      $(".drop-item").first().addClass("selected")
    }
  }
  function autocompleteDownKey() {
    if ($(".drop-item.selected").length > 0) {
      // prev because CSS reverses order
      var prev = $(".drop-item.selected").prev()
      if (prev) {
        $(".drop-item").removeClass("selected")
        prev.addClass("selected")
      }
    } else {
      // last because CSS reverses order
      $(".drop-item").last().addClass("selected")
    }
  }

  function omniUpKey() {
    var raw = omniRaw()
    if (history_idx == -1 && dashboard_history.length > 0) {
      history_hold = raw
      history_idx = 0
      $omnibar.val(dashboard_history[0])
    } else if (history_idx < dashboard_history.length - 1) {
      history_idx += 1
      $omnibar.val(dashboard_history[history_idx])
    }
  }
  function omniDownKey() {
    if (history_idx <= 0 && history_hold.length > 0) {
      history_idx = -1
      $omnibar.val(history_hold)
      history_hold = ""
    } else if (history_idx > 0) {
      history_idx -= 1
      $omnibar.val(dashboard_history[history_idx])
    }
  }
  function omniSubmit(evt) {
    var raw = omniRaw()
    var selector = omniSelector()
    var cmd = omniVal()

    if (dashboard_history[0] != raw.trim()) {
      dashboard_history.unshift(raw.trim())
    }
    history_hold = ""
    history_idx = -1
    if (raw == ".reload") {
      cells.forEach(function(cell) {
        cell.reload()
      })

      $omnibar.val([selector, ""].join(" "))
    }

    var cell = Cell.from_ele($(".dash-cell.active"))
    if (!cell) { return console.log("No cell selected") }

    var func_regex = /^ *\.\w+ */
    if (func_regex.test(cmd)) {
      var raw_func = cmd.match(func_regex)[0].slice(1).trim()
      var cmd = cmd.replace(func_regex, "")
      var func = cell.commands[raw_func]
      if (func && typeof(func) == "function") {
        func.call(cell, cmd)
      } else {
        func = cell[raw_func]
        if (func && typeof(func) == "function") {
          func.call(cell, cmd)
        } else {
          cell.execute("." + raw_func + " " + cmd)
        }
      }
    } else {
      cell.execute(cmd)
    }

    $omnibar.val(selector + " ")
  }

  $(document).on("click", ".dash-cell", function() {
    var cell = Cell.from_ele(this)
    if (cell) { cell.active(true) }
  }).on("keyup", function(evt) {
    var cell = Cell.from_selector(omniSelector())
    if (cell) {
      cell.active()
    } else {
      Cell.inactive()
    }

    if (!["ArrowUp", "ArrowDown", "Tab", "Enter"].includes(evt.key)) {
      resetDropup()
    }
  }).on("keydown", function(evt) {
    if (evt.key == "Escape") {
      Cell.blur()
      autocomplete_on = false
    }

    if (!evt.metaKey && $(".dash-cell.livekey").length > 0) {
      evt.preventDefault()
      evt.stopPropagation()
      return Cell.sendLivekey(evt.key)
    } else if (evt.metaKey) {
      return
    }

    $omnibar.focus()
    if (evt.key == "Tab") {
      evt.preventDefault()
      if (autocomplete_on) {
        autocompleteUpKey()
      } else {
        autocomplete_on = true
        resetDropup()
      }
      return
    } else if (evt.key == ">") {
      evt.preventDefault()
      evt.stopPropagation()

      Cell.startLivekey()
    }

    if (!autocomplete_on) { return }
    if (evt.key == "ArrowUp") {
      evt.preventDefault()
      evt.stopPropagation()

      autocompleteUpKey()
    } else if (evt.key == "ArrowDown") {
      evt.preventDefault()
      evt.stopPropagation()

      autocompleteDownKey()
    } else if (evt.key == "Enter") {
      $omnibar.val([omniSelector(), $(".drop-item.selected").text()].join(" "))
      autocomplete_on = false
      resetDropup()
    } else if (!evt.metaKey) {
      $omnibar.focus()
    }
  }).on("keydown", ".dashboard-omnibar input", function(evt) {
    if (autocomplete_on || $(".dash-cell.livekey").length > 0) { return }
    var raw = omniRaw()
    var selector = omniSelector()
    var cmd = omniVal()

    if (evt.key == "Enter") {
      omniSubmit(evt)
    } else if (evt.key == "ArrowUp") {
      evt.preventDefault()
      omniUpKey()
    } else if (evt.key == "ArrowDown") {
      evt.preventDefault()
      omniDownKey()
    }
  })
})
