$(".ctr-dashboard").ready(function() {
  cells = []
  Cell = function() {}
  Cell.init = function(data) {
    var cell = new Cell()
    var dash_cell = $("<div>", { class: "dash-cell" })
    dash_cell.append($("<div>", { class: "dash-title" }).append("<span></span>"))
    dash_cell.append($("<div>", { class: "dash-content" }))
    cell.ele = dash_cell

    cell.name = data.title.replace(/^\s*|\s*$/ig, "").replace(/\s+/ig, "-").replace(/[^a-z\-]/ig, "").toLowerCase()
    cell.title(data.title)
    cell.text(data.text)
    cell.x = data.x
    cell.y = data.y
    cell.w = data.w
    cell.h = data.h
    cell.interval = data.interval
    cell.command(data.command)
    cell.reloader(data.reloader, cell.interval)
    cell.setGridArea()
    if (data.socket) {
      cell.ws = new CellWS(cell, data.socket)
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
  Cell.prototype.reload = async function() {
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
  Cell.prototype.active = function() {
    $(".dash-cell").removeClass("active")
    this.ele.addClass("active")

    var prev = $(".dashboard-omnibar input").val()
    prev = prev.replace(/\:(\w|\-)+ /i, "")
    $(".dashboard-omnibar input").val(":" + this.name + " " + prev)
  }
  Cell.from_ele = function(ele) {
    var $ele = $(ele)

    return cells.find(function(cell) {
      return cell.ele.get(0) == $ele.get(0)
    })
  }

  CellWS = function(cell, data) {
    var cell_ws = this
    cell_ws.cell = cell
    cell_ws.open = false
    cell_ws.reload = false
    // cell_ws.socket = new WebSocket(data.url)
    cell_ws.socket = new ReconnectingWebSocket(data.url)

    if (data.authentication && typeof(data.authentication) === "function") {
      data.authentication(cell_ws)
    }

    cell_ws.socket.onopen = function() {
      // console.log("onopen");
      cell_ws.open = true
      cell_ws.send("subscribe", data.subscription)

      if (data.onopen && typeof(data.onopen) === "function") { data.onopen() }
      if (cell_ws.reload) {
        cells.forEach(function(cell) {
          cell.reload()
        })
        cell_ws.reload = false
      }
    }

    cell_ws.socket.onclose = function() {
      // console.log("onclose");
      cell_ws.open = false
      cell_ws.reload = true
      if (data.onclose && typeof(data.onclose) === "function") { data.onclose() }
    }

    cell_ws.socket.onerror = function(msg, a, b, c) {
      // console.log("onerror", msg, a, b, c);
    }

    cell_ws.socket.onmessage = function(msg) {
      // console.log("onmessage", msg);
      if (data.receive && typeof(data.receive) === "function") {
        var msg_data = JSON.parse(msg.data)
        if (msg_data.type == "ping" || !msg_data.message) { return }

        cell_ws.cell.flash()
        data.receive(cell_ws.cell, msg_data.message)
      }
    }
  }
  CellWS.prototype.send = function(command, data) {
    if (!data) {
      data = command
      command = "message"
    }
    var cell_ws = this
    if (cell_ws.open) {
      var msg = {
        command: command,
        identifier: JSON.stringify(data)
      }

      cell_ws.socket.send(JSON.stringify(msg))
    } else {
      setTimeout(function() {
        cell_ws.send(command, data)
      }, 500)
    }
  }

  $(document).on("click", ".dash-cell", function() {
    var cell = Cell.from_ele(this)

    if (cell) { cell.active() }
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

      // if (/^\./.test(cmd)) {}
      if (cmd == ".reload") {
        cell.reload()
      } else {
        cell.execute(cmd)
      }

      $(".dashboard-omnibar input").val(selector)
    }
  })
})
