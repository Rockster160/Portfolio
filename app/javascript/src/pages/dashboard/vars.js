import { Text } from "./_text"
import { ColorGenerator } from "./cells/color_generator"

export let text_height = 0.9 * 16
export let single_width = 32
export let cells = []
export let registered_cells = {}

// https://lospec.com/palette-list/endesga-32
export let dash_colors = {
  red:    "#A22633",
  yellow: "#FEE761",
  green:  "#3E8948",
  blue:   "#115DCD", // Not Endesga32
  lblue:  "#3D94F6", // Not Endesga32
  bright: "#5DA6F8", // Not Endesga32
  orange: "#f77622",
  white:  "#FFFFFF",
  darkgrey: "#262B44",
  black:  "#181425",
  grey:   "#8B9BB4",
}

export let temp_scale = ColorGenerator.colorScale({
  "#5B6EE1": 5,
  "#639BFF": 32,
  "#99E550": 64,
  "#FBF236": 78,
  "#AC3232": 96,
})

export let shiftTempToColor = function(temp, pad) {
  let color = temp_scale(temp)
  let str = Math.round(temp) + "°"

  return Text.color(color.hex, str.padStart(pad || 0, " "))
}
