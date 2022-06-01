import { Text } from "../_text"
import { dash_colors } from "../vars"

(function() {
  // Need a better way to get width of a cell
  var cell_width = 32/2, cell_height = 9 // Width /2 so that icons can be square
  var directions = [
    "up",
    "right",
    "down",
    "left",
  ]

  function blankCanvas() {
    return Array.from({ length: cell_height }, function() {
      return Array.from({ length: cell_width }, function() { return "  " })
    })
  }

  function draw(cell) {
    var cell = cell
    cell.text("")
    var canvas = blankCanvas()

    cell.data.body.forEach(function(coord) {
      var [x, y] = coord
      canvas[y][x] = " "
    })

    var [x, y] = cell.data.head
    canvas[y][x] = " "

    if (cell.data.apple) {
      var [x, y] = cell.data.apple
      canvas[y][x] = " "
    }

    cell.lines(canvas.map(function(line, idx) {
      if (idx == 0) {
        return Text.overlay(line.join(""), String(cell.data.score))
      } else {
        return line.join("")
      }
    }))
  }

  function tryDirect(cell, try_direction) {
    var new_direction = directions.indexOf(try_direction)
    var next = nextCoord(cell, new_direction)

    if (!coordListIncludes(cell.data.body, next)) {
      cell.data.direction = new_direction
    }
  }

  function nextCoord(cell, new_direction) {
    var new_coord = [cell.data.head[0], cell.data.head[1]]
    var motion = directions[new_direction || cell.data.direction]
    if (motion == "up") {
      new_coord[1] -= 1
    } else if (motion == "right") {
      new_coord[0] += 1
    } else if (motion == "down") {
      new_coord[1] += 1
    } else if (motion == "left") {
      new_coord[0] -= 1
    }
    new_coord[0] = wrap(new_coord[0], cell_width)
    new_coord[1] = wrap(new_coord[1], cell_height)

    return new_coord
  }

  function wrap(val, constraint) {
    if (val < 0) {
      return val = constraint - 1
    } else if (val > constraint - 1) {
      return val = 0
    } else {
      return val
    }
  }

  function rand(min, max) {
    if (max == undefined) {
      max = min
      min = 0
    }

    return Math.round((Math.random() * (max - min)) + min)
  }

  function randCoord() {
    return [rand(cell_width-1), rand(cell_height-1)]
  }

  function coordListIncludes(coordList, coord) {
    var matched_coord = coordList.find(function(list_coord) {
      return coordsMatch(list_coord, coord)
    })

    return matched_coord
  }

  function coordsMatch(coordA, coordB) {
    return coordA[0] == coordB[0] && coordA[1] == coordB[1]
  }

  function genApple(cell) {
    if (cell.data.apple) { return }

    var coord
    do {
      coord = randCoord()
    } while (coordListIncludes(cell.data.body, coord) || coordsMatch(cell.data.head, coord))
    // This is bad. It can potentially cause an infinite loop and be inefficient when the snake gets bigger

    cell.data.apple = coord
  }

  cell = Cell.register({
    title: "Snake",
    config: {
      game_speed: 100,
    },
    data: {
      gameover: false,
      paused: false,
      running: false,
      score: 0,
      full: 1,
      head: randCoord(),
      body: [],
      direction: 1,
      apple: null,
    },
    commands: {
      pause: function() {
        this.data.paused = !this.data.paused
        this.refreshInterval = this.data.paused ? null : this.config.game_speed
        this.reload()
      },
      reset: function() {
        this.data.gameover = false
        this.data.paused = false
        this.data.running = true
        this.data.head = randCoord()
        this.data.body = []
        this.data.full = 1
        this.data.score = 0
        this.data.apple = null
        this.refreshInterval = this.config.game_speed
        this.reload()
      }
    },
    flash: false,
    reloader: function() {
      var cell = this
      if (cell.data.paused) {
        var str = Text.center("Paused")
        var bg = Text.bgColor(dash_colors.grey, str)
        return cell.line(3, bg)
      }
      if (cell.data.gameover) {
        cell.refreshInterval = null
        var lose = Text.center("You Lose!")
        var color = Text.color(dash_colors.red, lose)
        var bg = Text.bgColor(dash_colors.grey, color)
        cell.line(3, bg)

        var replay = Text.center("Click 'r' to restart")
        cell.line(4, Text.bgColor(dash_colors.grey, replay))

        var old_high = parseInt(localStorage.getItem("snake_high") || 0)
        if (cell.data.score > old_high) {
          var high = Text.center("New High Score! Old score: " + old_high)
          cell.line(1, Text.bgColor(dash_colors.grey, high))

          localStorage.setItem("snake_high", cell.data.score)
        } else {
          var high = Text.center("High Score: " + old_high)
          cell.line(1, Text.bgColor(dash_colors.grey, high))
        }

        return
      }
      if (!cell.data.running) {
        var str = Text.center("Click cell then '>' to play")
        var bg = Text.bgColor(dash_colors.grey, str)
        return cell.line(3, bg)
      }
      genApple(cell)

      cell.data.body.unshift([cell.data.head[0], cell.data.head[1]])

      if (cell.data.full == 0) {
        cell.data.body.pop()
      } else {
        cell.data.full -= 1
      }

      var head = nextCoord(cell)
      if (coordListIncludes(cell.data.body, head)) {
        cell.data.gameover = true
      }
      if (coordsMatch(head, cell.data.apple)) {
        cell.data.full += 1
        cell.data.score += 1
        cell.data.apple = null
      }
      cell.data.head = head

      draw(cell)
    },
    onfocus: function() {
      this.data.running = true
      this.refreshInterval = this.config.game_speed
      this.reload()
    },
    onblur: function() {
      this.data.running = false
      this.refreshInterval = null
    },
    livekey: function(evt_key) {
      evt_key = evt_key.toLowerCase()
      if (evt_key == "arrowup" || evt_key == "w") {
        tryDirect(this, "up")
      } else if (evt_key == "arrowdown" || evt_key == "s") {
        tryDirect(this, "down")
      } else if (evt_key == "arrowleft" || evt_key == "a") {
        tryDirect(this, "left")
      } else if (evt_key == "arrowright" || evt_key == "d") {
        tryDirect(this, "right")
      } else if (evt_key.toLowerCase() == "p") {
        this.commands.pause.call(this)
      } else if (evt_key.toLowerCase() == "r" && (!this.data.running || this.data.gameover || this.data.paused)) {
        this.commands.reset.call(this)
      }
    }
  })
})()
