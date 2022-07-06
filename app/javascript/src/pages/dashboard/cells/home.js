import { Time } from "./_time"
import { Text } from "../_text"
import { ColorGenerator } from "./color_generator"
import { dash_colors } from "../vars"

(function() {
  var cell = undefined

  let renderLines = function() {
    let lines = []
    let first_row = []
    first_row.push(cell.data.loading ? "[ico ti ti-fa-spinner ti-spin]" : "")
    first_row.push(cell.data.failed ? Text.color(dash_colors.orange, "[FAILED]") : "")
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


    if (cell.data.garage) {
      if (cell.data.garage.open) {
        lines.push("[ico ti ti-mdi-garage_open]")
      } else {
        lines.push("[ico ti ti-mdi-garage]")
      }
    } else {
      lines.push("")
    }

    if (cell.data.amz_updates) {
      cell.data.amz_updates.forEach(function(order, idx) {
        lines.push(Text.justify((idx + 1) + ". " + order.name, order.delivery))
      })
    }

    cell.lines(lines)
  }

  let subscribeWebsockets = function() {
    cell.amz_socket = new CellWS(
      cell,
      Server.socket("AmzUpdatesChannel", function(msg) {
        this.flash()

        let data = []
        for (var [order_id, order_data] of Object.entries(msg)) {
          let order = { date: 0, id: order_id }
          let delivery = order_data.delivery || ""
          if (delivery[0] != "[") {
            let date = new Date(delivery + " MDT")
            order.date = date.getTime()
            delivery = date.toLocaleString("en-us", { weekday: "short", month: "short", day: "numeric" })
          }
          order.delivery = delivery
          order.name = order_data.name || "#"

          data.push(order)
        }
        this.data.amz_updates = data.sort(function(a, b) {
          return a.date - b.date
        })
        renderLines()
      })
    )
    cell.amz_socket.send({ action: "request" })

    cell.garage_socket = new CellWS(
      cell,
      Server.socket("GarageChannel", function(msg) {
        this.flash()

        console.log("Garage: ", JSON.stringify(msg))

        cell.data.garage = cell.data.garage || {}
        cell.data.garage.open = msg.garageState == "open"

        renderLines()
      })
    )
    cell.garage_socket.send({ action: "request" })

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
    onload: subscribeWebsockets,
    reloader: function() {
      // Update timer?
      // TODO: Have a different timer for resetting devices
      // get garage
    },
    started: function() {
      cell.amz_socket.reopen()
      cell.nest_socket.reopen()
    },
    stopped: function() {
      cell.amz_socket.close()
      cell.nest_socket.close()
    },
    command: function(msg) {
      // Also check if the number is even valid. If it's not, it's probably meant to be a temp
      if (/^-?\d+/.test(msg)) {
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
      } else if (/\b(open|close|toggle)\b/.test(msg)) { // open/close
        cell.garage_socket.send({ action: "control", direction: msg })
      } else { // Assume AC control
        cell.nest_socket.send({ action: "command", settings: msg })
        // up|main 74
        // up|main heat
        // up|main cool
      }
      // Garage
      // open
      // close
    }
  })
})()
