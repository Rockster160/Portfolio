import { Text } from "./_text"
import { ColorGenerator } from "./cells/color_generator"

export let text_height = 0.9 * 16
export let single_width = 32
export let cells = []
export let registered_cells = {}

// https://lospec.com/palette-list/endesga-32
export let dash_colors = {
  muted_purple: "#A082D9", // Not Endesga32
  red:      "#E91616", // Not Endesga32
  purple:   "#68386C",
  magenta:  "#B55088",
  yellow:   "#FEE761",
  green:    "#3E8948",
  blue:     "#115DCD", // Not Endesga32
  lblue:    "#3D94F6", // Not Endesga32
  rocco:    "#0160FF", // Not Endesga32
  bright:   "#5DA6F8", // Not Endesga32
  orange:   "#F77622",
  white:    "#FFFFFF",
  darkgrey: "#262B44",
  black:    "#181425",
  grey:     "#8B9BB4",
}
// Add helpers to the Text class for quickly setting colors
for (const [color, code] of Object.entries(dash_colors)) {
  Text[color] = (msg) => Text.color(code, msg)
}

export let scaleVal = function(value, f1, f2, t1, t2) {
  var tr = t2 - t1
  var fr = f2 - f1

  return (value - f1) * tr / fr + t1
}
export let clamp = function(a, b, c) {
  return [a, b, c].sort(function(a, b) { return a - b })[1]
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

// If you have another AudioContext class use that one, as some browsers have a limit
let audioCtx = new (window.AudioContext || window.webkitAudioContext || window.audioContext)

// -- All arguments are optional:

// `duration` of the tone in milliseconds. Default is 500
// `frequency` of the tone in hertz. default is 440
// `volume` of the tone. Default/Max is 1, off is 0. (>1 is allowed, but may be distorted)
// `type` of tone. Possible values are sine, square, sawtooth, triangle, and custom. Default is sine.
// `callback` to use at end of tone
export let beep = function(duration, frequency, volume, type, callback) {
  var oscillator = audioCtx.createOscillator()
  var gainNode = audioCtx.createGain()

  oscillator.connect(gainNode)
  gainNode.connect(audioCtx.destination)

  if (volume) { gainNode.gain.value = volume }
  if (frequency) { oscillator.frequency.value = frequency }
  if (type) { oscillator.type = type }
  if (callback) { oscillator.onended = callback }

  oscillator.start(audioCtx.currentTime)
  oscillator.stop(audioCtx.currentTime + ((duration || 500) / 1000))
}

export let beeps = function(beepsArray) {
  let currentIndex = 0

  function playNextBeep() {
    if (currentIndex < beepsArray.length) {
      const [duration, frequency, volume, type] = beepsArray[currentIndex]
      beep(duration, frequency, volume, type, playNextBeep)
      currentIndex++
    }
  }

  playNextBeep()
}
