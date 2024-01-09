import applyFrameModifiers from "./frame_modifiers"
import LiveStats from "./live_stats"

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
  onEvent("frame:move", function() {
    console.log("Frame moved");
    LiveStats.generate()
    //   checkStats = function() {
    //     var stats = $(".stats-holder")
    //     stats.html("")
    //
    //     if (!pin_mode_show || !should_check_stats) { return }
    //
    //     var toss = $(".shot.current")
    //     if (toss.length == 0) { return }
    //
    //     var bowler_id = toss.parents(".bowler").attr("data-bowler-id")
    //     if (bowler_id.length == 0) { return }
    //
    //     var shotIdx = shotIndex(toss)
    //     var first_throw = shotIdx == 0
    //     if (currentFrame() == 10) {
    //       first_throw = first_throw || (shotIdx == 1 && currentTossAtIdx(0).attr("data-score") == 10)
    //       first_throw = first_throw || (shotIdx == 2 && currentTossAtIdx(1).attr("data-score") == 10 || currentTossAtIdx(1).val() == "/")
    //     }
    //
    //     var url = stats.attr("data-stats-url")
    //
    //     var pins
    //     if (first_throw) {
    //       pins = undefined
    //     } else {
    //       pins = fallenPinsForShot(currentTossAtIdx(shotIndex(toss) - 1)).val()
    //     }
    //
    //     stats.html("<i class=\"fa fa-spinner fa-spin\"></i>")
    //
    //     $.get(url, { bowler_id: bowler_id, pins: pins }).done(function(data) {
    //       stats.html("")
    //       if (!data.stats.total) { return }
    //       var nums = data.stats.spare + " / " + data.stats.total
    //       var ratio = Math.round((data.stats.spare / data.stats.total) * 100)
    //
    //       $(".stats-holder").html(ratio + "%" + "</br>" + nums)
    //     })
    //   }
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
