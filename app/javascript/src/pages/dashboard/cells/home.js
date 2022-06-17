import { Time } from "./_time"
import { Text } from "../_text"
import { ColorGenerator } from "./color_generator"
import { dash_colors } from "../vars"

(function() {
  var cell = undefined

  // let color_scale = ColorGenerator.colorScale({
  //   "#5B6EE1": 5,
  //   "#639BFF": 32,
  //   "#99E550": 64,
  //   "#FBF236": 78,
  //   "#AC3232": 96,
  // })
  //
  // let shiftTempToColor = function(temp, pad) {
  //   let color = color_scale(temp)
  //   let str = Math.round(temp) + "°"
  //
  //   return Text.color(color.hex, str.padStart(pad || 0, " "))
  // }

  let cToF = function(c) {
    if (c == null || c == undefined) { return }

    return Math.round((c * (9/5)) + 32)
  }

  let fToC = function(f) {
    if (f == null || f == undefined) { return }

    return ((f - 32) * (5/9))
  }

  let capitalize = function(word) {
    return word.replace(/./, function(letter) { return letter.toUpperCase() })
  }

  let serializeDevice = function(device_data) {
    return {
      key:      device_data.name,
      name:     device_data.parentRelations[0].displayName == "Entryway" ? "Main" : "  Up",
      humidity: parseInt(device_data.traits["sdm.devices.traits.Humidity"].ambientHumidityPercent),
      current_mode: device_data.traits["sdm.devices.traits.ThermostatMode"].mode.toLowerCase(),
      current_temp: cToF(device_data.traits["sdm.devices.traits.Temperature"].ambientTemperatureCelsius),
      status:   device_data.traits["sdm.devices.traits.ThermostatHvac"].status.toLowerCase(),
      heat_set: cToF(device_data.traits["sdm.devices.traits.ThermostatTemperatureSetpoint"].heatCelsius),
      cool_set: cToF(device_data.traits["sdm.devices.traits.ThermostatTemperatureSetpoint"].coolCelsius),
    }
  }

  let getDevices = async function(count=0) {
    if (count > 1) {
      console.log("Get Devices failed again");
      return
    }

    let res = await fetch("https://smartdevicemanagement.googleapis.com/v1/enterprises/" + cell.config.project_id + "/devices", {
      method: "GET",
      headers: {
        "Content-Type": "application/json",
        "Authorization": cell.config.access_token,
      }
    })

    if (res.status == 401) {
      await refreshTokens()
      return getDevices(count + 1)
    }

    if (res.ok) {
      cell.data.devices = (await res.json()).devices.map(function(device_data) {
        return serializeDevice(device_data)
      })

      renderLines()
      cell.flash()
    }
  }

  let refreshTokens = async function() {
    let res = await fetch("https://www.googleapis.com/oauth2/v4/token", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": cell.config.access_token,
      },
      body: JSON.stringify({
        client_id:     cell.config.client_id,
        client_secret: cell.config.client_secret,
        refresh_token: cell.config.refresh_token,
        grant_type:    "refresh_token",
      })
    })

    if (res.ok) {
      let json = await res.json()
      cell.config.access_token = [json.token_type, json.access_token].join(" ")
    }
  }

  let setMode = async function(device, mode, count=0) {
    if (count > 1) {
      console.log("Set Mode failed again");
      return
    }

    let res = await fetch("https://smartdevicemanagement.googleapis.com/v1/" + device.key + ":executeCommand", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": cell.config.access_token,
      },
      body: JSON.stringify({
        command: "sdm.devices.commands.ThermostatMode.SetMode",
        params: {
          mode: mode.toUpperCase()
        }
      })
    })

    if (res.status == 401) {
      await refreshTokens()
      return setMode(device, mode, count + 1)
    }

    if (res.ok) {
      getDevices()
      // Schedule a few more refreshes to ping again soon
      setTimeout(function() { getDevices() }, Time.minute())
      setTimeout(function() { getDevices() }, Time.minutes(5))
    }
  }

  let setTemp = async function(device, temp, count=0) {
    if (count > 1) {
      console.log("Set Temp failed again");
      return
    }

    let mode = device.current_mode
    let data = {
      command: "sdm.devices.commands.ThermostatTemperatureSetpoint.Set" + capitalize(mode),
      params: {}
    }
    data["params"][mode + "Celsius"] = fToC(parseFloat(temp))

    let res = await fetch("https://smartdevicemanagement.googleapis.com/v1/" + device.key + ":executeCommand", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": cell.config.access_token,
      },
      body: JSON.stringify(data)
    })

    if (res.status == 401) {
      await refreshTokens()
      return setTemp(device, temp, count + 1)
    }

    if (res.ok) {
      getDevices()
    }
  }

  let renderLines = function() {
    let lines = []
    lines.push("") // Empty line just for looks

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

    // TODO: Garage

    if (cell.data.amz_updates) {
      lines.push("")

      cell.data.amz_updates.forEach(function(order, idx) {
        lines.push(Text.justify((idx + 1) + ". " + order.name, order.delivery))
      })
    }

    cell.lines(lines)
  }

  cell = Cell.register({
    title: "Home",
    refreshInterval: Time.minutes(10),
    wrap: false,
    flash: false,
    reloader: function() {
      getDevices(this)
      // get garage
      this.ws.send({ action: "request" })
    },
    socket: Server.socket("AmzUpdatesChannel", function(msg) {
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
    }),
    command: function(msg) {
      if (/^-?\d+/.test(msg)) {
        var num = parseInt(msg.match(/\d+/)[0])
        let order = this.data.amz_updates[num - 1]

        if (/^-\d+/.test(msg)) { // Use - to remove item
          this.ws.send({ action: "change", id: order.id, remove: true })
        } else if (/^\d+\s*$/.test(msg)) { // No words means open the order
          let url = "https://www.amazon.com/gp/your-account/order-details?orderID="
          window.open(url + order.id.replace("#", ""), "_blank")
        } else { // Rename the order
          this.ws.send({ action: "change", id: order.id, rename: msg.replace(/^\d+ /, "") })
        }
      } else { // Assume AC control
        let [area, mode, temp] = msg.split(" ")
        if (!temp) { temp = mode }

        this.data.devices?.forEach(function(device) {
          if (device.name.toLowerCase() == area.toLowerCase()) {
            if (mode == "heat" || mode == "cool") {
              setMode(device, mode)
            }

            if (temp && !Number.isNaN(Number(temp))) {
              setTemp(device, temp)
            }
          }
        })
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
