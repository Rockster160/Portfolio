import { AuthWS } from './auth_ws.js';
import { Widget } from './widget.js';

class Color {
  constructor(hex) {
    this.hex = hex

    let parts = hex.substring(1).match(new RegExp(`.{${Math.round(hex.length/3)}}`, "g"))
    parts = parts.map(part => part.length == 1 ? part.repeat(2) : part)
    parts = parts.map(part => parseInt(part, 16))

    let [r, g, b] = [...parts]
    this.r = r
    this.g = g
    this.b = b
    this.rgb = [r, g, b]
  }
}

class ColorMapper {
  constructor(mapping) {
    this.mapping = Object.entries(mapping).sort((a, b) => a[1] - b[1])
    const values = Object.values(mapping)
    this.minValue = Math.min(...values)
    this.maxValue = Math.max(...values)
  }

  scale(num) {
    let mapping = this.mapping, min, max
    for (let i = 0; i < mapping.length - 1; i++) {
      const a = mapping[i]
      const b = mapping[i+1]
      if (num >= a[1] && num < b[1]) {
        min = a
        max = b
        break
      }
    }
    if (min === undefined) {
      // Return the first/last val if num is outside of boundaries
      return mapping[0][1] >= num ? mapping[0][0] : mapping[mapping.length-1][1]
    }
    let min_color = new Color(min[0]), min_val = min[1]
    let max_color = new Color(max[0]), max_val = max[1]
    let new_rgb = [null, null, null].map(
      (_, t) => this.scaler(num, min_val, max_val, min_color.rgb[t], max_color.rgb[t])
    )

    return "#" + new_rgb.map(c => c.toString(16).padStart(2, "0")).join("").toUpperCase()
  }

  scaler(val, from_start, from_end, to_start, to_end) {
    let to_diff = to_end - to_start
    let from_diff = from_end - from_start

    return Math.round(((val - from_start) * to_diff) / from_diff) + to_start
  }
}

let colorMap = new ColorMapper({
  "#5B6EE1": 5,
  "#639BFF": 32,
  "#99E550": 64,
  "#FBF236": 78,
  "#AC3232": 96,
})

function shiftTempToColor(temp) {
  return span(temp + "°", `color: ${colorMap.scale(temp)}`)
}

function ico(str, style) {
  return `<i class="ti ti-${str}" style="${style}; padding: 0 3px;"></i>`
}

function span(str, style) {
  return `<span style="${style}">${str}</span>`
}

export let tesla = new Widget("tesla", function() {
  tesla.loading = true

  if (!tesla.data?.climate?.on) {
    tesla.socket.send({ action: "command", command: "on", params: {} })
  } else {
    tesla.socket.send({ action: "command", command: "off", params: {} })
  }
})
tesla.socket = new AuthWS("TeslaChannel", {
  onmessage: function(msg) {
    tesla.loading = msg.loading
    if (msg.failed) {
      tesla.error = true
      return
    } else {
      tesla.error = false
    }

    if ("climate" in msg) {
      tesla.data = msg
    } else {
      return
    }
    let lines = [], data = msg

    // Line 1 - Blank
    lines.push("")

    // Line 2 - Status (temp, charge, miles)
    let status_pieces = []
    if (data.climate?.current) {
      status_pieces.push(shiftTempToColor(data.climate.current))
    } else {
      status_pieces.push("?°")
    }
    status_pieces.push((data.charge || "?") + "%")
    status_pieces.push((data.miles || "?") + "m")
    lines.push(status_pieces.join(" | "))

    // Line 3 - Charging state
    if (data.charging?.active && data.charging.eta > 0 && data.charging.speed > 0 && !(data.drive?.speed > 0)) {
      let charging_text = "Full: " + data.charging.eta + "min | " + ico("weather-lightning") + data.charging.speed + "mph"
      lines.push(span(charging_text, "color: yellow;"))
    } else if ("charging" in data && !data.charging || data.charging.state == "Disconnected") {
      lines.push(span("[NOT CHARGING]", "color: red;"))
    } else {
      lines.push("")
    }

    // Line 4 - Blank
    lines.push("")

    // Line 5 - Open (Doors, windows, trunk, etc)
    if (data.open) {
      let opens = []
      if (data.open.ft > 0)        { opens.push("Frunk") }
      if (data.open.df > 0)        { opens.push("FDD") }
      if (data.open.fd_window > 0) { opens.push("FDW") }
      if (data.open.pf > 0)        { opens.push("FPD") }
      if (data.open.fp_window > 0) { opens.push("FPW") }
      if (data.open.dr > 0)        { opens.push("RDD") }
      if (data.open.rd_window > 0) { opens.push("RDW") }
      if (data.open.pr > 0)        { opens.push("RPD") }
      if (data.open.rp_window > 0) { opens.push("RPW") }
      if (data.open.rt > 0)        { opens.push("Trunk") }
      if (opens.length > 0) {
        lines.push("Open: " + opens.join(","))
      } else {
        lines.push("")
      }
    } else {
      lines.push("")
    }

    // Line 6 - Blank
    lines.push("")

    // Line 7 - Climate
    if (data.climate?.on) {
      let climate_text = "Climate: " //ico("mdi-fan ti-spin") - Not centered, so looks weird
      climate_text += span("[ON] ", "color: green;")
      climate_text += shiftTempToColor(data.climate.set)
      lines.push(climate_text)
    } else {
      lines.push(span("[OFF]", "color: grey;"))
    }

    // Line 8 - Locked / Location
    if (data.drive) {
      let lock = data.locked ? ico("fa-lock") : ico("fa-unlock")
      let drive_text = lock

      drive_text += ico("oct-location") + data.drive.location
      if (data.drive.speed > 0) { drive_text += ico("mdi-speedometer") + data.drive.speed + "mph" }
      lines.push(span(drive_text, "color: grey;"))
    } else {
      lines.push("")
    }

    tesla.lines = lines
    tesla.last_sync = data.timestamp * 1000
  },
  onopen: function() {
    tesla.connected()
    tesla.socket.send({ action: "request" })
  },
  onclose: function() {
    tesla.disconnected()
  }
})
tesla.refresh = function() {
  tesla.loading = true
  tesla.socket.send({ action: "command", command: "reload", params: {} })
}
tesla.tick = function() {
  // Do we want this page to refresh every hour?
  // if (tesla.state == "between" && tesla.delta() > 9 && tesla.delta() % 5 == 0) {
  //   tesla.refresh()
  // }
}
