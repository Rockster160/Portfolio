import { Time } from "./_time"
import { Text } from "../_text"
import { ColorGenerator } from "./color_generator"
import { dash_colors, beep, scaleVal, clamp } from "../vars"

(function() {
  var cell = undefined
  let flashing = undefined
  let flash_on = true

  let flash = function(active) {
    if (active) {
      flashing = flashing || setInterval(renderLines, 400)
    } else {
      clearInterval(flashing)
      flashing = undefined
    }
  }

  let battery_color_scale = ColorGenerator.colorScale((function() {
    let colors = {}
    colors[dash_colors.red]    = 30
    colors[dash_colors.yellow] = 50
    colors[dash_colors.green]  = 95
    return colors
  })())

  let batteryIcon = function(name, icon) {
    let data = cell.data.device_battery[name]
    let val = data.val
    if (!val) { return Text.color(dash_colors.grey, icon + "?") }
    let char = clamp(Math.round(scaleVal(val, 10, 90, 0, 7)), 0, 7)
    let level = "▁▂▃▄▅▆▇█"[char]
    let reported_at = Time.at(data.time)
    let battery_color = battery_color_scale(val).hex
    if (Time.now() - reported_at > Time.hours(12)) {
      battery_color = dash_colors.grey
    }
    return icon + Text.color(battery_color, level)
  }

  let renderLines = function() {
    let lines = []
    let first_row = []
    first_row.push(cell.data.loading ? "[ico ti ti-fa-spinner ti-spin]      " : "        ")

    if ("open" in (cell.data?.garage || {})) {
      if (cell.data.garage.open) {
        flash(false)
        first_row.push(Text.color(dash_colors.orange, "  [ico ti ti-mdi-garage_open]"))
      } else if (cell.data.garage.closed) {
        flash(false)
        first_row.push(Text.color(dash_colors.green, "  [ico ti ti-mdi-garage]"))
      } else {
        flash(true)
        if (flash_on = !flash_on) {
          first_row.push(Text.color(dash_colors.yellow, "  [ico ti ti-mdi-garage_open]"))
          if (cell.data.sound) {
            beep(100, 350, 0.02, "square")
          }
        } else {
          first_row.push(Text.color(dash_colors.yellow, "    "))
        }
      }
    } else {
      flash(false)
      first_row.push(Text.color(dash_colors.grey, " [ico ti ti-mdi-garage]?"))
    }

    first_row.push(cell.data.failed ? Text.color(dash_colors.orange, "[FAILED]") : "        ")

    lines.push(Text.justify(...first_row))

    cell.data.devices?.forEach(function(device) {
      let mode_color = device.current_mode == "cool" ? dash_colors.lblue : dash_colors.orange
      let name = device.name + ":"
      let current = device.current_temp + "°"
      let goal = Text.color(mode_color, "[" + (device.cool_set || device.heat_set) + "°]")
      let on = null
      if (device.status == "cooling") {
        on = Emoji.snowflake + Emoji.dash
      }
      if (device.status == "heating") {
        on = Emoji.fire + Emoji.dash
      }

      lines.push(Text.center([name, current, goal, on].join(" ")))
    })

    let battery_icons = {
      Phone:  "[ico ti ti-fa-mobile_phone]",
      Watch:  "[ico ti ti-oct-watch]",
      iPad:   "[ico ti ti-mdi-tablet_ipad]",
      Pencil: "[ico ti ti-mdi-pencil]",
    }
    let battery_line = []
    for (let [name, icon] of Object.entries(battery_icons)) {
      // Check last updated
      battery_line.push(batteryIcon(name, icon))
    }
    lines.push(Text.center(battery_line.join(" ")))

    if (cell.data.amz_updates) {
      cell.data.amz_updates.forEach(function(order, idx) {
        let today = Time.beginningOfDay()
        let delivery = order.delivery || ""
        if (delivery == "[DELIVERED]") {
          delivery = Text.color(dash_colors.green, "✓")
        } else if (delivery[0] != "[") {
          let [year, month, day, ...tz] = delivery.split(/-| /)
          let date = (new Date()).setFullYear(year, parseInt(month) - 1, day)
          let deliverTime = Time.at(date)
          delivery = deliverTime.toLocaleString("en-us", { weekday: "short", month: "short", day: "numeric" })

          if (today > deliverTime) {
            delivery = Text.color(dash_colors.orange, "Delayed?")
          } else if (today + Time.day() > deliverTime) {
            delivery = Text.color(dash_colors.green, "Today")
          } else if (today + Time.days(2) > deliverTime) {
            delivery = Text.color(dash_colors.yellow, "Tomorrow")
          }
        } else {
          delivery = Text.color(dash_colors.red, delivery)
        }

        lines.push(Text.justify((idx + 1) + ". " + order.name, delivery))
      })
    }

    cell.lines(lines)
  }

  let getGarage = function() {
    cell.recent_garage = false
    cell.garage_socket.send({ action: "request" })

    // If no response within 10 seconds, forget the current state
    clearTimeout(cell.garage_timeout)
    cell.garage_timeout = setTimeout(function() {
      if (!cell.recent_garage && cell.data.garage.hasOwnProperty("open")) {
        delete cell.data.garage.open
      }
      renderLines()
    }, Time.seconds(10))
  }

  let subscribeWebsockets = function() {
    cell.amz_socket = new CellWS(
      cell,
      Server.socket("AmzUpdatesChannel", function(msg) {
        this.flash()

        let data = []
        for (var [order_id, order_data] of Object.entries(msg)) {
          let order = { date: 0, id: order_id }
          let delivery = order_data.delivery
          if (delivery[0] != "[") {
            let [year, month, day, ...tz] = delivery.split(/-| /)
            order.date = (new Date()).setFullYear(year, parseInt(month) - 1, day)
          }
          order.name = order_data.name || "#"
          order.delivery = delivery

          data.push(order)
        }
        this.data.amz_updates = data.sort(function(a, b) {
          return a.date - b.date
        })
        renderLines()
      })
    )
    cell.amz_socket.send({ action: "request" })
    cell.device_battery_socket = new CellWS(
      cell,
      Server.socket("DeviceBatteryChannel", function(msg) {
        this.flash()

        if (msg.Phone) { cell.data.device_battery.Phone = msg.Phone }
        if (msg.iPad) { cell.data.device_battery.iPad = msg.iPad }
        if (msg.Watch) { cell.data.device_battery.Watch = msg.Watch }
        if (msg.Pencil) { cell.data.device_battery.Pencil = msg.Pencil }

        renderLines()
      })
    )
    cell.device_battery_socket.send({ action: "request" })

    cell.garage_socket = new CellWS(
      cell,
      Server.socket("GarageChannel", function(msg) {
        this.flash()

        if (msg.data == "refreshGarage") { getGarage() }

        cell.data.garage = cell.data.garage || {}
        if (msg.data?.garageState) {
          cell.recent_garage = true
          cell.data.garage.open = msg.data.garageState == "open"
          cell.data.garage.closed = msg.data.garageState == "closed"
          cell.data.garage.between = msg.data.garageState == "between"
        }

        renderLines()
      })
    )
    getGarage()
    setInterval(function() {
      getGarage()
    }, Time.hour())

    cell.nest_socket = new CellWS(
      cell,
      Server.socket("NestChannel", function(msg) {
        this.flash()

        if (msg.failed) {
          this.data.loading = false
          this.data.failed = true
          clearInterval(this.data.nest_timer) // Don't try anymore until we manually update
          renderLines()
          return
        } else {
          this.data.failed = false
        }
        if (msg.loading) {
          this.data.loading = true
          renderLines()
          return
        }

        this.data.loading = false
        this.data.devices = msg.devices

        renderLines()
      })
    )
    cell.nest_socket.send({ action: "command", settings: "update" })
    this.data.nest_timer = setInterval(function() {
      cell.nest_socket.send({ action: "command", settings: "update" })
    }, Time.minutes(10))
  }

  cell = Cell.register({
    title: "Home",
    refreshInterval: Time.minute(),
    wrap: false,
    flash: false,
    data: {
      sound: true,
      device_battery: {},
    },
    onload: subscribeWebsockets,
    reloader: function() {
      renderLines()
      // Update times? "1 minute ago", etc...
    },
    started: function() {
      cell.amz_socket.reopen()
      cell.device_battery_socket.reopen()
      cell.nest_socket.reopen()
      cell.garage_socket.reopen()
    },
    stopped: function() {
      cell.amz_socket.close()
      cell.device_battery_socket.close()
      cell.nest_socket.close()
      cell.garage_socket.close()
    },
    commands: {
      quiet: function() {
        cell.data.sound = !cell.data.sound
      }
    },
    command: function(msg) {
      if (/^-?\d+/.test(msg) && parseInt(msg.match(/\d+/)[0]) < 30) {
        var num = parseInt(msg.match(/\d+/)[0])
        let order = this.data.amz_updates[num - 1]

        if (/^-\d+/.test(msg)) { // Use - to remove item
          cell.amz_socket.send({ action: "change", id: order.id, remove: true })
        } else if (/^\d+\s*$/.test(msg)) { // No words means open the order
          let url = "https://www.amazon.com/gp/your-account/order-details?orderID="
          window.open(url + order.id.replace("#", ""), "_blank")
        } else { // Rename the order
          cell.amz_socket.send({ action: "change", id: order.id, rename: msg.replace(/^\d+ /, "") })
        }
      } else if (/^add\b/i.test(msg)) { // Add item to AMZ deliveries
        cell.amz_socket.send({ action: "change", add: msg })
      } else if (/\b(open|close|toggle|garage)\b/.test(msg)) { // open/close
        cell.garage_socket.send({ action: "control", direction: msg })
      } else { // Assume AC control
        cell.nest_socket.send({ action: "command", settings: msg })
      }
    }
  })
})()
