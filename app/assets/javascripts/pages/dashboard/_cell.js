$(".ctr-dashboard").ready(function() {
  var cells = []
  Cell = function(set_title, set_text, data) {
    this.name = set_title.replace(/^\s*|\s*$/ig, "").replace(/\s+/ig, "-").replace(/[^a-z\-]/ig, "").toLowerCase()
    this.my_title = set_title
    this.my_text = set_text
    data = data || {}
    this.my_x = data.x
    this.my_y = data.y
    this.my_w = data.w
    this.my_h = data.h
    this.my_data = data
    this.interval = undefined

    var cell = $("<div>", { class: "dash-cell" })
    cell.append($("<div>", { class: "dash-title" }).append("<span>" + set_title + "</span>"))
    cell.append($("<div>", { class: "dash-content" }).text(set_text))

    if (data.x) { cell.css({ gridColumnStart: "" + data.x }) }
    if (data.y) { cell.css({ gridRowStart: "" + data.y }) }
    if (data.w) { cell.css({ gridColumn: "span " + data.w }) }
    if (data.h) { cell.css({ gridRow: "span " + data.h }) }

    $(".dashboard").append(cell)
    cells.push(this)

    this.ele = cell
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
      this.my_text = new_text
      this.ele.children(".dash-content").text(new_text)
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
  Cell.prototype.reloader = function(callback, interval) {
    clearInterval(this.interval)

    if (callback && typeof(callback) === "function") { callback(this) }
    var cell = this
    if (interval != undefined) {
      this.interval = setInterval(function() {
        // Add class to highlight, showing an update is happening
        if (callback && typeof(callback) === "function") { callback(cell) }
      }, interval)
    }

    return this
  }
  Cell.prototype.execute = function(text) {
    text = text.replace(/\:(\w|\-)+ /i, "")
    
    if (this.my_command && typeof(this.my_command) === "function") { this.my_command(text) }
    console.log(this.name + " [" + text + "]");

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
})
