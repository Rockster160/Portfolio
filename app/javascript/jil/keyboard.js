export default class Keyboard {
  static #held = [];
  static get held() { return Keyboard.#held };
  static set held(keys) { Keyboard.#held = keys };
  constructor() {}

  static isPressed(keys) {
    keys = Array.isArray(keys) ? keys : [keys]
    return keys.every(key => Keyboard.held.includes(key))
  }

  static on(keys, callback) {
    document.addEventListener("keyboard:press", (evt) => {
      if (Keyboard.isPressed(keys)) { callback(evt.detail.evt) }
    })
  }
}

document.addEventListener("keydown", function(evt) {
  if (!Keyboard.held.includes(evt.key)) {
    Keyboard.held = [...Keyboard.held, evt.key]
    document.dispatchEvent(new CustomEvent("keyboard:press", { detail: { evt: evt } }))
  }
})

document.addEventListener("keyup", function(evt) {
  Keyboard.held = Keyboard.held.filter(key => key != evt.key)
})
