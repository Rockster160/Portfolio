// resetPinTimer → game.pinTimer.reset()
export function events() {
  onEvent("pin:change", function(evt) {
    // console.log("pin change", evt.detail);
    game.saved = false
    if (game.currentShot) {
      game.currentShot.standingPins = game.pins.standing
    }
  })
  onEvent("shot:change", function(evt) {
    const { shot } = evt.detail
    // console.log(`shot changed`, shot);
  })
  onEvent("frame:move", function(evt) {
    const { previousShot, currentShot } = evt.detail
    // console.log(`frame move`, currentShot, previousShot);

    game.resyncElements()
    game.showStats()
    game.saveScores()
  })
}

export function trigger(evtName, detail) {
  document.dispatchEvent(new CustomEvent(evtName, {
    bubbles: true,
    detail: detail
  }))
}

export function lastSelector(wrapper, selector) {
  let lastItem = null
  wrapper.querySelectorAll(selector).forEach(item => lastItem = item)
  return lastItem
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
        if (selector.includes("&>")) {
          selector = selector.split(/, ?/).map(i => {
            return i.includes("&>") ? i.replace(/(.*?) &>/, "$1, $1 *") : i
          }).join(", ")
        }
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
