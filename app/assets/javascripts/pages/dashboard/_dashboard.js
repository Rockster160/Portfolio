$(".ctr-dashboard").ready(function() {
  cells = []
  Cell = function() {}
  Cell.init = function(init_data) {
    var cell = new Cell()
    var dash_cell = $("<div>", { class: "dash-cell" })
    dash_cell.append($("<div>", { class: "dash-title" }).append("<span></span>"))
    dash_cell.append($("<div>", { class: "dash-content" }))
    cell.ele = dash_cell

    cell.name = (init_data.name || init_data.title).replace(/^\s*|\s*$/ig, "").replace(/\s+/ig, "-").replace(/[^a-z\-]/ig, "").toLowerCase()
    cell.title(init_data.title)
    cell.text(init_data.text)
    cell.x = init_data.x
    cell.y = init_data.y
    cell.w = init_data.w
    cell.h = init_data.h
    cell.init_data = init_data
    cell.data = init_data.data || {}
    cell.commands = init_data.commands || {}
    cell.interval = init_data.interval
    cell.command(init_data.command)
    cell.reloader(init_data.reloader, cell.interval)
    cell.setGridArea()
    if (init_data.socket) {
      cell.ws = new CellWS(cell, init_data.socket)
    }

    $(".dashboard").append(dash_cell)
    cells.push(cell)
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
      // Should escape raw HTML as well
      new_text = Text.escape(new_text)
      this.my_text = new_text
      this.ele.children(".dash-content").html(new_text)
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
  Cell.prototype.reload = function() {
    var cell = this
    if (cell.my_reloader && typeof(cell.my_reloader) === "function") {
      cell.my_reloader(cell)
    }

    if (cell.interval != undefined) {
      cell.timer = setTimeout(function() {
        cell.reload()
      }, cell.interval)
    }

    cell.flash()

    return cell
  }
  Cell.prototype.reloader = function(callback, interval) {
    var cell = this

    clearTimeout(cell.timer)
    cell.my_reloader = callback

    cell.reload()

    return cell
  }
  Cell.prototype.execute = function(text) {
    if (this.my_command && typeof(this.my_command) === "function") { this.my_command(text, this) }

    return this
  }
  Cell.prototype.command = function(command) {
    if (command && typeof(command) === "function") { this.my_command = command }

    return this
  }
  Cell.prototype.stop = function() {
    console.log("stop");
    var cell = this
    clearTimeout(cell.timer)
    if (cell.ws) { cell.ws.close() }
  }
  Cell.prototype.start = function() {
    console.log("start");
    var cell = this
    if (cell.ws) { cell.ws.reopen() }
    cell.reload()
  }
  Cell.prototype.hide = function(a, b, c, d) {
    console.log("hide");
    var cell = this
    cell.ele.addClass("hide")
  }
  Cell.prototype.show = function() {
    console.log("show");
    var cell = this
    cell.ele.removeClass("hide")
  }
  Cell.prototype.active = function(reset_omnibar) {
    $(".dash-cell").removeClass("active")
    this.ele.addClass("active")
    if (!reset_omnibar) { return }

    var prev = $(".dashboard-omnibar input").val()
    prev = prev.replace(/\:(\w|\-)+ ?/i, "")
    $(".dashboard-omnibar input").val(":" + this.name + " " + prev)
  }
  Cell.inactive = function() {
    $(".dash-cell").removeClass("active")
  }
  Cell.from_selector = function(selector) {
    return cells.find(function(cell) {
      return cell.my_title.toLowerCase() == selector.toLowerCase()
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
    // cell_ws.socket = new WebSocket(init_data.url)
    cell_ws.socket = new ReconnectingWebSocket(init_data.url)

    if (init_data.authentication && typeof(init_data.authentication) === "function") {
      init_data.authentication(cell_ws)
    }

    cell_ws.socket.onopen = function() {
      cell_ws.open = true
      cell_ws.send("subscribe", init_data.subscription)

      if (init_data.onopen && typeof(init_data.onopen) === "function") { init_data.onopen() }
      if (cell_ws.reload) {
        cell_ws.cell.reload()
        cell_ws.reload = false
      }
    }

    cell_ws.socket.onclose = function() {
      cell_ws.open = false
      cell_ws.reload = true
      if (init_data.onclose && typeof(init_data.onclose) === "function") { init_data.onclose() }
    }

    cell_ws.socket.onerror = function(msg, a, b, c) {
    }

    cell_ws.socket.onmessage = function(msg) {
      if (init_data.receive && typeof(init_data.receive) === "function") {
        var msg_data = JSON.parse(msg.data)
        if (msg_data.type == "ping" || !msg_data.message) { return }

        cell_ws.cell.flash()
        init_data.receive(cell_ws.cell, msg_data.message)
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
  CellWS.prototype.send = function(command, packet) {
    if (!packet) {
      packet = command
      command = "message"
    }
    var cell_ws = this
    if (cell_ws.open) {
      // This part is what would be defined by the packet data function rather than making opinionated decisions
      var msg = {
        command: command,
        identifier: JSON.stringify(packet)
      }

      cell_ws.socket.send(JSON.stringify(msg))
    } else {
      setTimeout(function() {
        cell_ws.send(command, packet)
      }, 500)
    }
  }

  $(document).on("click", ".dash-cell", function() {
    var cell = Cell.from_ele(this)

    if (cell) { cell.active(true) }
  }).on("keyup", function(evt) {
    var raw = $(".dashboard-omnibar input").val()
    var selector = raw.match(/(?:\:)(\w|\-)+/i)
    selector = selector ? selector[0].slice(1) : ""

    var cell = Cell.from_selector(selector)
    if (cell) {
      cell.active()
    } else {
      Cell.inactive()
    }
  }).on("keydown", function(evt) {
    if (!evt.metaKey) {
      $(".dashboard-omnibar input").focus()
    }
  }).on("keypress", ".dashboard-omnibar input", function(evt) {
    if (evt.which == keyEvent("ENTER")) {
      var raw = $(".dashboard-omnibar input").val()
      var selector = raw.match(/\:(\w|\-)+ /i)
      selector = selector ? selector[0] : ""
      var cmd = raw.replace(/\:(\w|\-)+ /i, "")

      if (raw == ".reload") {
        cells.forEach(function(cell) {
          cell.reload()
        })

        $(".dashboard-omnibar input").val(selector)
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

      $(".dashboard-omnibar input").val(selector)
    }
  })
})
