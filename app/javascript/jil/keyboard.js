export default class Keyboard {
  static #held = new Set();
  static get held() { return Keyboard.#held };
  static set held(keys) { Keyboard.#held = keys };
  constructor() {}

  static isPressed(keys) {
    keys = Array.isArray(keys) ? keys : [keys]
    return keys.every(key => Keyboard.held.has(key))
  }

  static on(keys, callback) {
    if (keys.includes("Meta")) {
      // metaKey causes a LOT of weirdness with keys because it doesn't trigger a keyup event
      // Instead, treat it as a one-off
      document.addEventListener("keydown", function(evt) {
        if (evt.key === "Meta" || evt.key === "Shift") { return }
        const correctMeta = evt.metaKey
        const correctShift = (keys.includes("Shift") && evt.shiftKey) || (!keys.includes("Shift") && !evt.shiftKey)
        if (correctMeta && correctShift && keys.includes(evt.key) && Keyboard.held.size == 0) {
          evt.preventDefault()
          callback(evt)
        }
      })
      return
    }
    document.addEventListener("keyboard:press", (evt) => {
      if (Keyboard.isPressed(keys)) { callback(evt.detail.evt) }
    })
  }
}

document.addEventListener("keydown", function(evt) {
  if (evt.metaKey) { return } // metaKey causes a LOT of weirdness with keys because it doesn't trigger a keyup event
  if (!Keyboard.held.has(evt.key)) {
    Keyboard.held.add(evt.key)
    document.dispatchEvent(new CustomEvent("keyboard:press", { detail: { evt: evt } }))
  }
})

document.addEventListener("keyup", function(evt) {
  if (evt.metaKey) { return } // metaKey causes a LOT of weirdness with keys because it doesn't trigger a keyup event
  Keyboard.held.delete(evt.key)
})
