import applyFrameModifiers from "./frame_modifiers"

// resetPinTimer → game.pinTimer.reset()
export function events() {
  onEvent("pin:change", function() {
    if (game.currentShot) {
      game.currentShot.standingPins = game.pins.standing
    }
  })
  onEvent("frame:change", function() {
    applyFrameModifiers(game.currentFrame)
  })
}

export function onEvent(events, selector, callback) {
  if (selector && typeof selector == "function") {
    callback = selector
    selector = null
  }

  events.split(" ").forEach(eventName => {
    document.addEventListener(eventName, function(evt) {
      if (selector) {
        let ele = evt.target
        if (ele && ele.matches(selector)) { callback.call(ele, evt) }
      } else {
        callback.call(window, evt)
      }
    })
  })
}

export function onKey(key, selector, keycallback) {
  if (selector && typeof selector == "function") {
    keycallback = selector
    selector = null
  }

  onEvent("keyup keydown keypress", selector, function(evt) {
    if (key.split(" ").includes(evt.key)) {
      keycallback.call(this, evt)
    }
  })
}

export function onKeyUp(key, selector, keycallback) {
  if (selector && typeof selector == "function") {
    keycallback = selector
    selector = null
  }

  onEvent("keyup", selector, function(evt) {
    if (key.split(" ").includes(evt.key)) {
      keycallback.call(this, evt)
    }
  })
}

export function onKeyDown(key, selector, keycallback) {
  if (selector && typeof selector == "function") {
    keycallback = selector
    selector = null
  }

  onEvent("keydown", selector, function(evt) {
    if (key.split(" ").includes(evt.key)) {
      keycallback.call(this, evt)
    }
  })
}

export function onKeyPress(key, selector, keycallback) {
  if (selector && typeof selector == "function") {
    keycallback = selector
    selector = null
  }

  onEvent("keypress", selector, function(evt) {
    if (key.split(" ").includes(evt.key)) {
      keycallback.call(this, evt)
    }
  })
}
