export class ColorGenerator {
  constructor() {
    this.rgb = undefined
    this.hex = undefined
  }

  static fromRGB(r, g, b) {
    let gen = new ColorGenerator()
    return gen.fromRGB(r, g, b)
  }

  static fromHex(hex) { // Include "#" in hex
    let gen = new ColorGenerator()
    return gen.fromHex(hex)
  }

  static fadeBetweenHex(hex1, hex2, steps) {
    let color1 = ColorGenerator.fromHex(hex1)
    let color2 = ColorGenerator.fromHex(hex2)

    return color1.fadeTo(color2, steps)
  }

  static fadeBetweenRGB(rgb1, rgb2, steps) {
    let color1 = ColorGenerator.fromRGB(...rgb1)
    let color2 = ColorGenerator.fromRGB(...rgb2)

    return color1.fadeTo(color2, steps)
  }

  static colorScale(color_scale) {
    let color_shift = Object.keys(color_scale).map(function(this_color, idx) {
      var this_temp = color_scale[this_color]
      var next_color = Object.keys(color_scale)[idx+1]
      var next_temp = color_scale[next_color]

      if (next_color) {
        return ColorGenerator.fadeBetweenHex(this_color, next_color, next_temp - this_temp)
      }
    }).flat().filter(function(col) { return col })

    let scaleVal = function(value, f1, f2, t1, t2) {
      var tr = t2 - t1
      var fr = f2 - f1

      return (value - f1) * tr / fr + t1
    }

    let vals = Object.values(color_scale).sort(function(a, b) { return a - b })
    let min_val = vals[0]
    let max_val = vals[vals.length - 1]

    return function(val) {
      let scaled_idx = Math.round(scaleVal(val, min_val, max_val, 0, color_shift.length - 1))
      let constrained_idx = [scaled_idx, 0, color_shift.length - 1].sort(function(a, b) {
        return a - b
      })[1]

      return color_shift[constrained_idx]
    }
  }

  fromRGB(r, g, b) {
    this.rgb = [r, g, b]

    this.hex = "#" + this.rgb.map(function(color) {
      let constrain = [Math.round(color), 0, 255].sort(function(a, b) { return a - b })[1]
      let hex = constrain.toString(16)

      return hex.padStart(2, hex)
    }).join("").toUpperCase()

    return this
  }

  fromHex(new_hex) {
    new_hex = new_hex.replace("#", "").toUpperCase()
    if (new_hex.length == 3){
      new_hex = new_hex.split(/(.{1})/).map(function(hex_char) {
        return [hex_char, hex_char].join("")
      }).join("")
    }

    this.hex = "#" + new_hex
    this.rgb = new_hex.split(/(.{2})/).filter(function(str) {
      return str.length == 2
    }).map(function(hex_val) {
      return parseInt(hex_val, 16)
    })

    return this
  }

  fadeToHex(hex, steps) {
    return fadeTo(ColorGenerator.fromHex(hex), steps)
  }

  fadeToRGB(r, g, b, steps) {
    return fadeTo(ColorGenerator.fromRGB(r, g, b), steps)
  }

  fadeTo(new_color, steps) {
    steps = (steps || 256) - 1
    let [r1, g1, b1] = this.rgb
    let [r2, g2, b2] = new_color.rgb
    let [rsteps, gsteps, bsteps] = [(r2 - r1) / steps, (g2 - g1) / steps, (b2 - b1) / steps]

    return Array(steps + 1).fill().map(function(_, step) {
      return ColorGenerator.fromRGB(r1 + (rsteps * step), g1 + (gsteps * step), b1 + (bsteps * step))
    })
  }
}
