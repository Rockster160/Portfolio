export default class Pins {
  constructor() {
    this.pinEles = this.allPins.map(pinNum => {
      return document.querySelector(`.pin-wrapper[data-pin-num='${pinNum}']`)
    })
    this.pinEles.unshift(null) // Add empty space at the beginning of the array to align num to idx
    this.standing = this.allPins
    this._fallen_before = []
    this.broadcast = true
  }

  noBroadcast(fn) {
    this.broadcast = false
    fn()
    this.broadcast = true
  }

  get allPins() { return Array.from({ length: 10 }, (_, pinNum) => pinNum+1) }

  get standing() { return this._current_standing }
  set standing(standing_pins) {
    let pins = this.pinsFromInput(standing_pins)
    this._current_standing = pins

    this.allPins.forEach(pinNum => this.toggle(pinNum, pins.includes(pinNum)))
  }
  get fallen() { return this.invert(this.standing) }
  set fallen(fallen_pins) { return this.standing = this.invert(fallen_pins) }
  get fallenBefore() { return this._fallen_before }
  set fallenBefore(fallen_pins) {
    this._fallen_before.forEach(pinNum => {
      if (!fallen_pins.includes(pinNum)) {
        this.pinEles[pinNum].classList.remove("fallen-before")
      }
    })
    this._fallen_before = fallen_pins
    fallen_pins.forEach(pinNum => this.pinEles[pinNum].classList.add("fallen-before"))
  }

  checkStanding(pinNum) { return this._current_standing.includes(pinNum) }

  standAll() { this.toggleAll(true) }
  knockAll() { this.toggleAll(false) }
  stand(pinNum) { this.toggle(pinNum, true) }
  knock(pinNum) { this.toggle(pinNum, false) }

  toggleAll(direction) { this.allPins.forEach(pinNum => this.toggle(pinNum, direction)) }
  toggle(pinNum, force_direction) {
    let standing = typeof force_direction == "boolean" ? force_direction : !this._current_standing.includes(pinNum)

    let pin = this.pinEles[pinNum]
    if (standing) {
      if (this.checkStanding(pinNum)) { return } // Already standing
      this._current_standing.push(pinNum)
      pin.classList.remove("fallen")
    } else {
      if (!this.checkStanding(pinNum)) { return } // Already fallen
      this._current_standing = this._current_standing.filter(standingPin => standingPin != pinNum)
      pin.classList.add("fallen")
    }
    if (this.broadcast) {
      pin.dispatchEvent(new CustomEvent("pin:change", { bubbles: true, detail: { pin: pinNum } }))
    }
  }

  invert(standing_pins) {
    let pins = this.pinsFromInput(standing_pins)
    return this.allPins.filter(function(pin) { return !pins.includes(pin) })
  }

  decToPins(integer) {
    let binary = integer.toString(2)
    const zerosToAdd = Math.max(0, 10 - binary.length)
    let binStr = "0".repeat(zerosToAdd) + binary
    return binStr.split("").reverse().map(function(num, idx) {
      if (num == "1") { return idx+1 }
    }).filter(Boolean).sort()
  }

  pinsFromInput(standing_pins) {
    if (Array.isArray(standing_pins)) {
      return standing_pins.map(int => parseInt(int))
    } else if (typeof standing_pins == "number") {
      return this.pinsFromInput(this.decToPins(standing_pins))
    } else {
      console.log("Unknown Pin Type: ", typeof standing_pins, standing_pins);
    }
  }

  checkSplit(standing_pins) {
    let pins = this.pinsFromInput(standing_pins)
    if (pins.length == 0) { return false }
    if (pins.includes(1)) { return false }

    var columns = [
      [7],
      [4],
      [2, 8],
      [1, 5],
      [3, 9],
      [6],
      [10],
    ]

    return !!columns.map(function(col_pins) {
      return col_pins.filter(function(col) {
        return pins.includes(col)
      }).length > 0 ? "1" : "0"
    }).join("").match(/10+1/)
  }
}
