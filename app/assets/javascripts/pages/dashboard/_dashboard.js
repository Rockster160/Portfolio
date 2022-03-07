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
    cell.x(data.x)
    cell.y(data.y)
    cell.w(data.w)
    cell.h(data.h)
    cell.interval = data.interval
    cell.command(data.command)
    cell.reloader(data.reloader, cell.interval)

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
  Cell.prototype.x = function(new_x) {
    if (new_x == undefined) {
      return this.my_x
    } else {
      this.my_x = new_x
      this.ele.css({ gridColumnStart: "" + new_x })
      return this
    }
  }
  Cell.prototype.y = function(new_y) {
    if (new_y == undefined) {
      return this.my_y
    } else {
      this.my_y = new_y
      this.ele.css({ gridRowStart: "" + new_y })
      return this
    }
  }
  Cell.prototype.w = function(new_w) {
    if (new_w == undefined) {
      return this.my_w
    } else {
      this.my_w = new_w
      this.ele.css({ gridColumn: "span " + new_w })
      return this
    }
  }
  Cell.prototype.h = function(new_h) {
    if (new_h == undefined) {
      return this.my_h
    } else {
      this.my_h = new_h
      this.ele.css({ gridRow: "span " + new_h })
      return this
    }
  }
  Cell.prototype.reload = function() {
    if (this.my_reloader && typeof(this.my_reloader) === "function") { this.my_reloader(this) }

    var cell = this
    cell.ele.addClass("flash")
    setTimeout(function() {
      cell.ele.removeClass("flash")
    }, 1000)

    return this
  }
  Cell.prototype.reloader = function(callback, interval) {
    var cell = this
    cell.my_reloader = callback

    clearInterval(cell.timer)
    cell.reload()

    if (interval != undefined) {
      cell.timer = setInterval(function() {
        cell.reload()
      }, interval)
    }

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
