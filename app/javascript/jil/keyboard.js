const mapKey = (key) => {
  return {
    " ":          "Space",
    "ArrowUp":    "↑",
    "ArrowLeft":  "←",
    "ArrowRight": "→",
    "ArrowDown":  "↓",
  }[key] || key
}

export default class Keyboard {
  static #held = new Set();
  static get held() { return Keyboard.#held };
  static set held(keys) { Keyboard.#held = keys };
  constructor() {}

  static isPressed(keys) {
    keys = Array.isArray(keys) ? keys : [keys]
    return keys.every(key => Keyboard.held.has(mapKey(key)))
  }

  static on(combos, callback) {
    combos = Array.isArray(combos) ? combos : [combos]
    combos.forEach(keys => {
      keys = keys.split("+")
      const metaKey = keys.includes("Meta")
      const shiftKey = keys.includes("Shift")
      const controlKey = keys.includes("Control")
      const modifiersMatch = (evt) => {
        if (metaKey !== !!evt.metaKey) { return false }
        if (shiftKey !== !!evt.shiftKey) { return false }
        if (controlKey !== !!evt.controlKey) { return false }
        return true
      }
      keys = keys.map(key => mapKey(key))

      if (metaKey) {
        // Special behavior for Meta/Cmd because it doesn't trigger the same way as other keys
        keys = keys.filter(key => key !== "Meta" && key !== "Shift" && keys !== "Control")
        if (keys.length !== 1) { throw `Invalid keys: [${JSON.stringify(keys)}] - can only be 1.` }
        const key = keys[0].toLowerCase()

        document.addEventListener("keydown", function(evt) {
          if (modifiersMatch(evt) && key === mapKey(evt.key).toLowerCase()) {
            // evt.preventDefault()
            callback(evt)
          }
        })
        return
      }
      document.addEventListener("keyboard:press", (evt) => {
        if (!modifiersMatch(evt)) { return }
        if (Keyboard.isPressed(keys)) { callback(evt.detail.evt) }
      })
    })
  }
}

// NOTE: Keys are uppercase when <Shift> is pressed and "special" with <Alt>
// Can use `evt.code` which looks like "KeyC" or "ControlLeft" if needed.
document.addEventListener("keydown", function(evt) {
  console.log(evt)
  if (evt.metaKey) { return } // metaKey causes a LOT of weirdness with keys because it doesn't trigger a keyup event
  if (!Keyboard.held.has(mapKey(evt.key))) {
    Keyboard.held.add(mapKey(evt.key))
    console.log(Keyboard.held)
    document.dispatchEvent(new CustomEvent("keyboard:press", { detail: { evt: evt } }))
  }
})

document.addEventListener("keyup", function(evt) {
  if (evt.metaKey) { return } // metaKey causes a LOT of weirdness with keys because it doesn't trigger a keyup event
  Keyboard.held.delete(mapKey(evt.key))
  console.log(Keyboard.held)
})
