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
    let [r1, g1, b1] = this.rgb
    let [r2, g2, b2] = new_color.rgb
    let steps = (steps || 256) - 1
    let [rsteps, gsteps, bsteps] = [(r2 - r1) / steps, (g2 - g1) / steps, (b2 - b1) / steps]

    return Array(steps + 1).fill().map(function(_, step) {
      return ColorGenerator.fromRGB(r1 + (rsteps * step), g1 + (gsteps * step), b1 + (bsteps * step))
    })
  }
}
