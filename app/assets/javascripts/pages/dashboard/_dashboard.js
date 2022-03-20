$(".ctr-dashboard").ready(function() {
  var dashboard_history = [], history_idx = -1, history_hold = ""
  var autocomplete_on = false
  var $omnibar = $(".dashboard-omnibar input")

  cells = []
  Cell = function() {}
  Cell.init = function(init_data) {
    var cell = new Cell()
    var dash_cell = $("<div>", { class: "dash-cell" })
    dash_cell.append($("<div>", { class: "dash-title" }).append("<span></span>"))
    dash_cell.append($("<div>", { class: "dash-content" }))
    cell.ele = dash_cell

    cell.name = (init_data.name || init_data.title).replace(/^\s*|\s*$/ig, "").replace(/\s+/ig, "-").replace(/[^a-z\-]/ig, "").toLowerCase()
    cell.title(init_data.title || "")
    cell.text(init_data.text || "")
    cell.should_flash = init_data.flash == false ? false : true
    cell.x = init_data.x
    cell.y = init_data.y
    cell.w = init_data.w
    cell.h = init_data.h
    cell.init_data = init_data
    cell.data = init_data.data || {}
    cell.commands = init_data.commands || {}
    cell.autocomplete_options = init_data.autocomplete_options || cell.command_list
    cell.interval = init_data.interval
    if (init_data.socket) {
      cell.ws = new CellWS(cell, init_data.socket)
    }
    cell.command(init_data.command)
    cell.reloader(init_data.reloader, cell.interval)
    cell.setGridArea()

    $(".dashboard").append(dash_cell)
    cells.push(cell)
    return cell
  }
  Cell.prototype.title = function(new_title) {
    if (new_title == undefined) {
      return this.my_title
    } else {
      this.my_title = new_title
      this.ele.children(".dash-title").children("span").text(new_title)
      return this
    }
  }
  Cell.prototype.text = function(new_text) {
    if (new_text == undefined) {
      return this.my_text
    } else {
      new_text = Text.escape(new_text)
      this.my_text = new_text
      this.ele.children(".dash-content").html(Text.markup(new_text))
      return this
    }
  }
  Cell.prototype.lines = function(new_lines) {
    if (new_lines == undefined) {
      return this.text().split("\n")
    } else {
      this.text(new_lines.join("\n"))
      return this
    }
  }
  Cell.prototype.line = function(idx, new_line) {
    if (new_line == undefined) {
      return this.text().split("\n")[idx]
    } else {
      var lines = this.text().split("\n")
      lines[idx] = new_line
      this.lines(lines)
      return this
    }
  }
  Cell.prototype.data = function(new_data) {
    if (new_data == undefined) {
      return this.my_data
    } else {
      this.my_data = new_data
      return this
    }
  }
  Cell.prototype.setGridArea = function() {
    var area = {
      rowStart: this.y || "auto",
      colStart: this.x || "auto",
      rowEnd: this.h ? "span " + this.h : "auto",
      colEnd: this.w ? "span " + this.w : "auto",
    }

    var pieces = [area.rowStart, area.colStart, area.rowEnd, area.colEnd]

    this.ele.css({ gridArea: pieces.join(" / ") })
  }
  Cell.prototype.flash = function() {
    var cell = this

    cell.ele.addClass("flash")
    setTimeout(function() {
      cell.ele.removeClass("flash")
    }, 1000)

    return this
  }
  Cell.prototype.resetTimer = function(new_interval) {
    var cell = this
    clearTimeout(cell.timer)
    cell.timer = undefined
    cell.interval = new_interval

    if (new_interval != undefined) {
      cell.timer = setTimeout(function() {
        cell.reload()
      }, cell.interval)
    }
  }
  Cell.prototype.reload = function() {
    var cell = this
    if (cell.my_reloader && typeof(cell.my_reloader) === "function") {
      cell.my_reloader()
    }

    cell.resetTimer(cell.interval)

    if (cell.should_flash) { cell.flash() }

    return cell
  }
  Cell.prototype.reloader = function(callback, interval) {
    var cell = this

    clearTimeout(cell.timer)
    cell.my_reloader = callback

    cell.reload()

    return cell
  }
  Cell.prototype.command_list = function() {
    var commands = [
      ".reload",
      ".debug",
      ".start",
      ".stop",
      ".hide",
      ".show",
    ]
    Object.keys(this.commands).reverse().forEach(function(cmd) {
      if (!commands.includes("." + cmd)) {
        commands.push("." + cmd)
      }
    })
    return commands.reverse()
  }
  Cell.prototype.autocomplete = function(text) {
    var options = []
    if (this.autocomplete_options && typeof(this.autocomplete_options) === "function") {
      options = this.autocomplete_options(text)
    } else {
      options = autocomplete_options
    }

    return Text.filterOrder(text, options)
  }
  Cell.prototype.execute = function(text) {
    if (this.my_command && typeof(this.my_command) === "function") { this.my_command(text) }

    return this
  }
  Cell.prototype.command = function(command) {
    if (command && typeof(command) === "function") { this.my_command = command }

    return this
  }
  Cell.prototype.debug = function() {
    var cell = this
    console.log(cell)
  }
  Cell.prototype.stop = function() {
    var cell = this
    clearTimeout(cell.timer)
    if (cell.ws) { cell.ws.close() }
  }
  Cell.prototype.start = function() {
    var cell = this
    if (cell.ws) { cell.ws.reopen() }
    cell.reload()
  }
  Cell.prototype.hide = function() {
    var cell = this
    cell.ele.addClass("hide")
  }
  Cell.prototype.show = function() {
    var cell = this
    cell.ele.removeClass("hide")
  }
  Cell.prototype.active = function(reset_omnibar) {
    $(".dash-cell").removeClass("active")
    this.ele.addClass("active")
    if (!reset_omnibar) { return }

    var prev = $omnibar.val()
    prev = prev.replace(/\:(\w|\-)+ ?/i, "")
    $omnibar.val(":" + this.name + " " + prev)
  }
  Cell.inactive = function() {
    $(".dash-cell").removeClass("active")
  }
  Cell.from_selector = function(selector) {
    selector = selector.toLowerCase().replace(/^:/, "")
    return cells.find(function(cell) {
      return cell.name.toLowerCase() == selector
    })
  }
  Cell.from_ele = function(ele) {
    var $ele = $(ele)

    return cells.find(function(cell) {
      return cell.ele.get(0) == $ele.get(0)
    })
  }

  CellWS = function(cell, init_data) {
    var cell_ws = this
    cell_ws.cell = cell
    cell_ws.open = false
    cell_ws.reload = false
    cell_ws.presend = init_data.presend
    // cell_ws.socket = new WebSocket(init_data.url)
    cell_ws.socket = new ReconnectingWebSocket(init_data.url)
    // cell_ws.send = init_data.send || function(packet) { cell_ws.push(packet) }

    cell_ws.socket.onopen = function() {
      cell_ws.open = true

      if (init_data.authentication && typeof(init_data.authentication) === "function") {
        init_data.authentication.call(cell_ws)
      }

      if (init_data.onopen && typeof(init_data.onopen) === "function") { init_data.onopen.call(cell_ws) }
      if (cell_ws.reload) {
        cell_ws.cell.reload()
        cell_ws.reload = false
      }
    }

    cell_ws.socket.onclose = function() {
      cell_ws.open = false
      cell_ws.reload = true
      if (init_data.onclose && typeof(init_data.onclose) === "function") { init_data.onclose.call(cell_ws) }
    }

    cell_ws.socket.onerror = function(msg, a, b, c) {
    }

    cell_ws.socket.onmessage = function(msg) {
      if (init_data.receive && typeof(init_data.receive) === "function") {
        if (cell_ws.should_flash) { cell_ws.cell.flash() }
        init_data.receive.call(cell_ws.cell, msg)
      }
    }
  }
  CellWS.prototype.reopen = function() {
    var cell_ws = this
    cell_ws.cell.ws = new CellWS(cell_ws.cell, cell_ws.cell.init_data.socket)
  }
  CellWS.prototype.close = function() {
    var cell_ws = this
    cell_ws.open = false
    cell_ws.socket.close()
  }
  // Packet data should be another function on WS that can be defined for pre-formatting ws messages
  CellWS.prototype.send = function(packet) {
    var cell_ws = this
    if (cell_ws.open) {
      if (cell_ws.presend && typeof(cell_ws.presend) === "function") {
        packet = cell_ws.presend(packet)
      }

      cell_ws.socket.send(JSON.stringify(packet))
    } else {
      setTimeout(function() {
        cell_ws.send(packet)
      }, 500)
    }
  }

  var omniRaw = function() { return $omnibar.val() }
  var omniSelector = function() {
    var selector = omniRaw().match(/(?:\:)(\w|\-)+/i)
    return selector ? selector[0] : ""
  }
  var omniVal = function() {
    return omniRaw().replace(/\:(\w|\-)+\s*/i, "")
  }
  var autocompleteOptions = function() {
    var cell = Cell.from_ele($(".dash-cell.active"))
    if (cell) {
      return cell.autocomplete(omniVal())
    } else {
      var cell_names = cells.map(function(cell) { return ":" + cell.name + " " })
      return Text.filterOrder(omniVal(), cell_names)
    }
  }
  var resetDropup = function() {
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

  $(document).on("click", ".dash-cell", function() {
    var cell = Cell.from_ele(this)

    if (cell) { cell.active(true) }
    $omnibar.focus()
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
    $omnibar.focus()
    if (evt.key == "Tab") {
      evt.preventDefault()
      if (autocomplete_on) {
        // Duplicate of ArrowUp
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
      } else {
        autocomplete_on = true
        resetDropup()
      }
      return
    }

    if (!autocomplete_on) { return }
    if (evt.key == "Escape") {
      autocomplete_on = false
    } else if (evt.key == "ArrowUp") {
      evt.preventDefault()
      evt.stopPropagation()

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
    } else if (evt.key == "ArrowDown") {
      evt.preventDefault()
      evt.stopPropagation()

      if ($(".drop-item.selected").length > 0) {
        // prev because CSS reverses order
        var prev = $(".drop-item.selected").prev()
        if (prev) {
          $(".drop-item").removeClass("selected")
          prev.addClass("selected")
        }
      } else {
        // first because CSS reverses order
        $(".drop-item").last().addClass("selected")
      }
    } else if (evt.key == "Enter") {
      $omnibar.val([omniSelector(), $(".drop-item.selected").text()].join(" "))
      autocomplete_on = false
      resetDropup()
    } else if (!evt.metaKey) {
      $omnibar.focus()
    }
    // evt.key == ">"
    // Enter cell. Add a new class for the cell that makes it "focused"
    // `Esc` will break out of focus mode.
    // During Focus, all key events are sent directly to the cell.
    // Can be used for inline editing or live key events.
  }).on("keydown", ".dashboard-omnibar input", function(evt) {
    if (autocomplete_on) { return }
    var raw = omniRaw()
    var selector = omniSelector()
    var cmd = omniVal()

    if (evt.key == "Enter") {
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
    } else if (evt.key == "ArrowUp") {
      evt.preventDefault()
      if (history_idx == -1 && dashboard_history.length > 0) {
        history_hold = raw
        history_idx = 0
        $omnibar.val(dashboard_history[0])
      } else if (history_idx < dashboard_history.length - 1) {
        history_idx += 1
        $omnibar.val(dashboard_history[history_idx])
      }
    } else if (evt.key == "ArrowDown") {
      evt.preventDefault()
      if (history_idx <= 0 && history_hold.length > 0) {
        history_idx = -1
        $omnibar.val(history_hold)
        history_hold = ""
      } else if (history_idx > 0) {
        history_idx -= 1
        $omnibar.val(dashboard_history[history_idx])
      }
    }
  })
})
