import { text_height, single_width, cells, registered_cells } from "./vars"
import { Text } from "./_text"

Cell = function() {}
Cell.register = function(init_data) {
  var cell = new Cell()
  var dash_cell = $("<div>", { class: "dash-cell" })
  dash_cell.append($("<div>", { class: "dash-title" }).append("<span></span>"))
  dash_cell.append($("<div>", { class: "dash-content" }))
  cell.ele = dash_cell

  cell.name = String(init_data.name || init_data.title).replace(/^\s*|\s*$/ig, "").replace(/\s+/ig, "-").replace(/[^a-z\-]/ig, "").toLowerCase()
  cell.title(init_data.title || "")
  cell.text(init_data.text || "")
  cell.should_flash = init_data.flash == false ? false : true
  cell.init_data = init_data
  cell.wrap = init_data.wrap || false
  cell.data = init_data.data || {}
  cell.config = init_data.config || {}
  cell.commands = init_data.commands || {}
  cell.onlook = init_data.onlook || undefined
  cell.onload = init_data.onload || undefined
  cell.onblur = init_data.onblur || undefined
  cell.onfocus = init_data.onfocus || undefined
  cell.livekey = init_data.livekey || undefined
  cell.autocomplete_options = init_data.autocomplete_options || cell.command_list
  cell.refreshInterval = init_data.refreshInterval

  var cell_key = cell.name.replace(/-/g, "_")
  registered_cells[cell_key] = cell
  return cell
}
Cell.initByName = function(name, config) {
  var cell_key = name.replace(/^\s*|\s*$/ig, "").replace(/\s+/ig, "_").replace(/[^a-z_]/ig, "").toLowerCase()
  var cell = registered_cells[cell_key]
  delete registered_cells[cell_key]
  if (!cell) {
    return console.error("Cannot find cell registered with name: ", cell_key);
  }

  return Cell.init(cell, config)
}
Cell.init = function(cell, config) {
  cell.config = Object.assign(cell.config, config)
  cell.setGridArea()
  if (cell.init_data.socket) {
    cell.ws = new CellWS(cell, cell.init_data.socket)
  }

  cells.push(cell)
  $(".dashboard").append(cell.ele)

  if (cell.onload && typeof(cell.onload) === "function") { cell.onload() }
  cell.command(cell.init_data.command)
  cell.refreshInterval = cell.config.refreshInterval || cell.refreshInterval
  cell.reloader(cell.init_data.reloader, cell.refreshInterval)
  return cell
}
Cell.loadConfig = function(all_config) {
  for (var [name, config] of Object.entries(all_config)) {
    Cell.initByName(name, config)
  }
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
  var cell = this
  if (new_text == undefined) {
    return cell.my_text
  } else {
    new_text = Text.escape(new_text)
    cell.my_text = new_text
    new_text = Text.markup(new_text)
    new_text = new_text.split("\n").map(function(line) {
      var wrap_class = cell.wrap ? "" : "nowrap"
      return Text.fixHeight("<div class=\"line " + wrap_class + "\">" + (line || " ") + "</div>")
    }).join("")
    cell.ele.children(".dash-content").html(new_text)
    cell.ele.find(".line").each(function() {
      var line_height = $(this).height()
      var rows = Math.round(line_height / text_height)
      if (rows > 1) { return }
      // Let this just auto wrap- there is currently a bug where single lines think they're bigger.
      $(this).css({ height: (rows || 1) * text_height + "px" })
    })
    return cell
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
    rowStart: this.config.y || "auto",
    colStart: this.config.x || "auto",
    rowEnd: this.config.h ? "span " + this.config.h : "auto",
    colEnd: this.config.w ? "span " + this.config.w : "auto",
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
  cell.refreshInterval = new_interval

  if (new_interval != undefined) {
    cell.timer = setTimeout(function() {
      cell.reload()
    }, cell.refreshInterval)
  }
}
Cell.prototype.reload = function() {
  var cell = this
  if (cell.my_reloader && typeof(cell.my_reloader) === "function") {
    cell.my_reloader()
  }

  cell.resetTimer(cell.refreshInterval)

  if (cell.should_flash) { cell.flash() }

  return cell
}
Cell.prototype.reloader = function(callback, refreshInterval) {
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
  if (!$(this.ele).hasClass("livekey")) { Cell.blur() }
  $(".dash-cell").removeClass("active")
  this.ele.addClass("active")
  if (this && this.onlook && typeof(this.onlook) === "function") { this.onlook() }
  if (!reset_omnibar) { return }

  var omnibar = $(".dashboard-omnibar input")
  var prev = omnibar.val()
  prev = prev.replace(/\:(\w|\-)+ ?/i, "")
  omnibar.val(":" + this.name + " " + prev)
}
Cell.active = function() {
  return Cell.from_ele($(".dash-cell.active"))
}
Cell.getLivekey = function() {
  return Cell.from_ele($(".dash-cell.livekey"))
}
Cell.blur = function() {
  var cell = Cell.getLivekey()
  if (cell && cell.onblur && typeof(cell.onblur) === "function") { cell.onblur() }
  $(".dash-cell").removeClass("livekey")
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
    return cell.ele.get(0) === $ele.get(0)
  })
}
Cell.startLivekey = function() {
  var cell = Cell.active()

  if (cell && cell.livekey && typeof(cell.livekey) === "function") {
    $(cell.ele).addClass("livekey")
    if (cell.onfocus && typeof(cell.onfocus) === "function") { cell.onfocus() }
  }
}
Cell.sendLivekey = function(evt_key) {
  var cell = Cell.getLivekey()

  if (cell && cell.livekey && typeof(cell.livekey) === "function") {
    cell.livekey(evt_key)
  }
}

CellWS = function(cell, init_data) {
  var cell_ws = this
  cell_ws.cell = cell
  cell_ws.open = false
  cell_ws.reload = false
  cell_ws.presend = init_data.presend
  // cell_ws.socket = new WebSocket(init_data.url)
  cell_ws.socket = new ReconnectingWebSocket(init_data.url)

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
