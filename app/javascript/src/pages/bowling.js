import { Spinner } from "./spinner"

$(".ctr-bowling_leagues.act-tms").ready(function() {
  var calcAvgChange = function(bowler, new_val) {
    new_val = parseInt(new_val)
    if (isNaN(new_val)) { return "" }
    var games = parseInt(bowler.attr("data-gms"))
    var pins = parseInt(bowler.attr("data-pins"))
    var series = parseInt(bowler.attr("data-gms-per-series"))
    var old_avg = pins / games
    if (new_val < old_avg * 2) { new_val = new_val * 3 }

    var new_pins = pins + new_val
    var new_games = games + series

    return Math.floor(new_pins / new_games)
  }

  $(".quick-avg-check").keyup(function() {
    var bowler = $(this).parents(".league-bowler")
    var newAvg = calcAvgChange(bowler, $(this).val())

    bowler.children(".quick-avg-out").text(newAvg)
  })
})
$(".ctr-bowling_leagues.act-edit, .ctr-bowling_leagues.act-new").ready(function() {
  $(".league-roster").sortable({
    handle: ".bowler-handle",
    update: function(evt, ui) { updateRoster() }
  })

  $("#bowling_league_team_size").change(function() { updateRoster() })

  updateRoster = function() {
    var roster = $(".league-roster")
    roster.find(".bowler-form:not(.hidden)").each(function(idx) {
      $(this).find(".position").val(idx + 1)
    })

    var team_size = parseInt($("#bowling_league_team_size").val()) || 1
    $(".in-roster").remove()
    $(".bowler-form:not(.hidden)").each(function(idx) {
      if (idx + 1 > team_size) { return }

      var star = $("<i>", { class: "fa fa-star in-roster" })
      $(this).append(star)
    })
  }
  updateRoster()

  $(document).on("click", ".remove-bowler", function(evt) {
    var bowler = $(this).parents(".bowler-form")

    if (bowler.find(".bowler-id").val() == "") {
      bowler.remove()
    } else {
      bowler.find(".should-destroy").val(true)
      bowler.addClass("hidden")
    }

    updateRoster()
  })

  var template = document.querySelector("#bowler-template")
  $(".add-bowler").click(function() {
    var clone = template.content.cloneNode(true)

    $(".league-roster").append(clone)
    updateRoster()
  })
})


$(".ctr-bowling_games.act-new, .ctr-bowling_games.act-edit").ready(function() {
  var inProgress = false
  var pin_knock = undefined
  var pinTimer = undefined
  var timer_duration = 1000
  var spinner = new Spinner({
    size: 55,
    stroke: 5,
    duration: timer_duration,
    color: "#2196F3",
  })
  var should_check_stats = true

  var editing = false
  var pin_mode_show = true

  $(".bowling-edit").click(function(evt) {
    editing = !editing
    resetEdits()

    evt.preventDefault()
    return false
  })
  $(".pin-mode-toggle").click(function(evt) {
    pin_mode_show = !pin_mode_show
    resetPinMode()

    evt.preventDefault()
    return false
  })
  $(".timer-toggle").click(function() {
    $(this).toggleClass("active")
    if (!$(this).hasClass("active")) { resetPinTimer() }
  })
  $(".timer-toggle").append(spinner.element)

  function resetEdits() {
    if (editing) {
      $("[data-edit]").removeClass("hidden")
      $("[data-edit=hide]").addClass("hidden")
    } else {
      $("[data-edit]").addClass("hidden")
      $("[data-edit=hide]").removeClass("hidden")
    }
  }
  resetEdits()

  function resetPinMode() {
    if (pin_mode_show) {
      $("[data-pins-show=show]").removeClass("hidden")
      $("[data-pins-show=hide]").addClass("hidden")
    } else {
      $("[data-pins-show=show]").addClass("hidden")
      $("[data-pins-show=hide]").removeClass("hidden")
    }
  }
  resetPinMode()

  resetStrikePoint = function() {
    $(".pocket-toggle, .brooklyn-toggle").removeClass("active")
    var shot = $(".shot.current")
    var strike_point = shot.parents(".frame").find(".strike-point").val()

    strikePoint(strike_point)
  }

  strikePoint = function(direction) {
    $(".pocket-toggle, .brooklyn-toggle").removeClass("active")

    if (direction == "pocket") {
      $(".shot.current").parents(".frame").find(".strike-point").val("pocket")
      $(".pocket-toggle").addClass("active")
    } else if (direction == "brooklyn") {
      $(".shot.current").parents(".frame").find(".strike-point").val("brooklyn")
      $(".brooklyn-toggle").addClass("active")
    } else {
      $(".shot.current").parents(".frame").find(".strike-point").val("")
    }
  }

  $(".pin-all-toggle").on("click", function(evt) {
    clearTimeout(pinTimer)
    if ($(this).hasClass("fall")) {
      $(".pin-wrapper:not(.fallen-before)").addClass("fallen")
    } else {
      $(".pin-wrapper:not(.fallen-before)").removeClass("fallen")
    }
    $(this).toggleClass("fall")
  })
  $(".pocket-toggle").click(function() {
    var prev_val = $(".shot.current").parents(".frame").find(".strike-point").val()
    strikePoint(prev_val == "pocket" ? null : "pocket")
  })
  $(".brooklyn-toggle").click(function() {
    var prev_val = $(".shot.current").parents(".frame").find(".strike-point").val()
    strikePoint(prev_val == "brooklyn" ? null : "brooklyn")
  })
  $(".close-frame, .pocket-close, .brooklyn-close").on("click", function() {
    $(".pin-wrapper:not(.fallen-before)").addClass("fallen").trigger("pin:change")
    if ($(this).hasClass("pocket-close")) { strikePoint("pocket") }
    if ($(this).hasClass("brooklyn-close")) { strikePoint("brooklyn") }

    addScore("X")
  })
  $(".next-frame").on("click", function(evt) {
    recountPins()
    var toss = $(".shot.current")
    var shot_idx = parseInt(toss.attr("data-shot-idx"))
    var nextShot = toss.parents(".frame").find(".shot").filter(function() {
      return parseInt($(this).attr("data-shot-idx")) > shot_idx
    })

    recalculateFrame(toss)

    if (toss.parents(".frame").attr("data-frame") == "10") {
      if (shot_idx == 0) {
        moveToThrow(nextShot.first())
      } else if (shot_idx == 1) {
        if (currentTossAtIdx(0).val() == "X") {
          moveToThrow(nextShot.first())
        } else {
          moveToNextFrame()
        }
      } else if (shot_idx == 2) {
        moveToNextFrame()
      }
    } else if (nextShot.length > 0 && toss.val() != "X") {
      moveToThrow(nextShot.first())
    } else {
      moveToNextFrame()
    }
  })
  $(".pin-wrapper").on("pin:change", function() {
    var shot_idx = parseInt($(".shot.current").attr("data-shot-idx"))
    $(".shot.current").parents(".frame").find(".shot").filter(function() {
      var next = parseInt($(this).attr("data-shot-idx")) > shot_idx
      if (!next) { return false }

      return fallenPinsForShot(this).val() == ""
    }).each(function() {
      clearShot(this)
    })

    recountPins()
    resetPinTimer()
  })
  $(document).on("click touchstart", function(evt) {
    var is_input = evt.target.tagName == "INPUT" || evt.target.tagName == "LABEL"
    if (is_input || $(evt.target).hasClass("numpad-key")) { return }
    evt.preventDefault()
    pin_knock = undefined

    var target = $(evt.target)
    if (target.hasClass("pin")) {
      pin_knock = !target.parents(".pin-wrapper:not(.fallen-before)").hasClass("fallen")
      target.parents(".pin-wrapper:not(.fallen-before)").toggleClass("fallen").trigger("pin:change")
    }
    return false
  }).on("touchend", function(evt) {
    var target = $(evt.target)

    if (target.hasClass("pin")) {
      evt.preventDefault()
    }
  }).on("mousemove", function(evt) {
    if (evt.which != 1) { return }

    if ($(".pin:hover").length > 0) {
      evt.preventDefault()

      if (pin_knock == undefined) {
        pin_knock = !$(".pin:hover").parents(".pin-wrapper:not(.fallen-before)").hasClass("fallen")
      } else if (pin_knock) {
        $(".pin:hover").parents(".pin-wrapper:not(.fallen-before)").addClass("fallen").trigger("pin:change")
      } else {
        $(".pin:hover").parents(".pin-wrapper:not(.fallen-before)").removeClass("fallen").trigger("pin:change")
      }
    }
  })
  $(".bowling-keypad-entry").on("mousemove, touchmove", function(evt) {
    evt.preventDefault()
    var xPos = evt.originalEvent.touches[0].pageX
    var yPos = evt.originalEvent.touches[0].pageY

    var $target = $(document.elementFromPoint(xPos, yPos))
    if (!$target.hasClass("pin")) { return }

    if (pin_knock == undefined) {
      pin_knock = !$target.parents(".pin-wrapper:not(.fallen-before)").hasClass("fallen")
    } else if (pin_knock) {
      $target.parents(".pin-wrapper:not(.fallen-before)").addClass("fallen").trigger("pin:change")
    } else {
      $target.parents(".pin-wrapper:not(.fallen-before)").removeClass("fallen").trigger("pin:change")
    }
    return false
  })

  swap = function($ele1, $ele2) {
    var temp = $("<div>")

    $ele1.before(temp)
    $ele2.before($ele1)
    temp.before($ele2).remove()
  }

  clearShot = function(shot) {
    shot = $(shot)
    shot.val("").removeAttr("data-score")
    shot.parents(".split-holder").removeClass("split")
    fallenPinsForShot(shot).val("")
    shot.parents(".frame").find(".score").text("")
  }

  fallenPinsForShot = function(shot) {
    shot = $(shot)
    return shot.parents(".frame").find(".fallen-pins[data-shot-idx=" + shot.attr("data-shot-idx") + "]")
  }

  resetBowlerOrder = function() {
    $(".bowler").each(function(idx) {
      $(this).attr("data-bowler", idx + 1)
      $(this).find(".game-position").val(idx + 1)
    })
  }

  window.onbeforeunload = function(evt) {
    if (!inProgress) {
      return undefined
    }

    return "onbeforeunload"
  }

  $(document).on("modal.shown", function() {
    $(".shot.current").removeClass("current")
  }).on("modal.hidden", function() {
    gotoNextFrame()
  })

  $(document).on("submit", ".add-new-bowler", function(evt) {
    evt.preventDefault()

    var form = $(this)
    var url = form.attr("action")

    $.post(url, form.serialize()).done(function(data, status, xhr) {
      var in_bowler = $(data.html)
      var out_bowler_id = $(".sub-out-name").attr("data-bowler-id")
      var out_bowler = $(".bowler[data-bowler-id=" + out_bowler_id + "]")

      $("#bowler_name").val("")
      $("#bowler_total_games_offset").val("")
      $("#bowler_total_pins_offset").val("")

      $($("#game-sub-list").get(0).content).append(in_bowler)
      hideModal("#bowler-sub-list")
      if (out_bowler.length > 0) {
        swap(in_bowler, out_bowler)
      } else {
        $(in_bowler).insertBefore(".bowler-placeholder")
      }
      resetEdits()
      resetBowlerOrder()
      calcScores()
    })
  })

  $(document).on("click", ".bowler-select", function(evt) {
    var out_bowler_id = $(".sub-out-name").attr("data-bowler-id")
    var in_bowler_id = $(this).attr("data-bowler-id")

    var in_bowler = $($("#game-sub-list").get(0).content).find(".bowler[data-bowler-id=" + in_bowler_id + "]")
    var out_bowler = $(".bowler[data-bowler-id=" + out_bowler_id + "]")

    hideModal("#bowler-sub-list")
    if (out_bowler.length > 0) {
      swap(in_bowler, out_bowler)
    } else {
      $(in_bowler).insertBefore(".bowler-placeholder")
    }
    resetEdits()
    resetBowlerOrder()
    calcScores()
  })

  $(document).on("click", ".bowler-sub-btn", function(evt) {
    var name = $(this).attr("data-bowler-name")
    $(".sub-out-name").text(name).attr("data-bowler-id", $(this).attr("data-bowler-id"))
    $(".sub-message").removeClass("hidden")

    $(".bowler-select").removeClass("hidden")
    $(".bowler").each(function() {
      $(".bowler-select[data-bowler-id=" + $(this).attr("data-bowler-id") + "]").addClass("hidden")
    })

    showModal("#bowler-sub-list")
  }).on("click", ".new-bowler", function(evt) {
    $(".sub-message").addClass("hidden")
    $(".bowler-select").removeClass("hidden")
    $(".bowler").each(function() {
      if (!$(this).attr("data-bowler-id")) { return }
      $(".bowler-select[data-bowler-id=" + $(this).attr("data-bowler-id") + "]").addClass("hidden")
    })

    showModal("#bowler-sub-list")
  }).on("click", ".edit-bowler-name", function(evt) {
    evt.preventDefault()
    evt.stopPropagation()
    var name = prompt("Enter bowler name")
    if (name.length < 1) { return }

    var bowler = $(this).parents(".bowler")

    bowler.find(".name").html(name)
    bowler.find(".bowler-options-name").html(name)
    bowler.find(".bowler-name-field").val(name)
    bowler.find(".bowler-sub-btn").attr("data-bowler-name", name)
  })

  $(document).on("change", ".absent-checkbox", function() {
    var absent = $(this).prop("checked")
    var bowler = $(this).parents(".bowler")

    if (absent) {
      bowler.addClass("absent")
      bowler.find(".absent-bowler").removeClass("hidden")
      bowler.find(".shot").val("").attr("data-score", "")
    } else {
      bowler.removeClass("absent")
      bowler.find(".absent-bowler").addClass("hidden")
      // Remove absent frame scores
      bowler.find(".score").text("")
    }
    calcScores()
  })

  $(document).on("change", ".skip-checkbox", function() {
    var skip = $(this).prop("checked")
    var bowler = $(this).parents(".bowler")

    if (skip) {
      bowler.addClass("skip")
      bowler.find(".skip-bowler").removeClass("hidden")
    } else {
      bowler.removeClass("skip")
      bowler.find(".skip-bowler").addClass("hidden")
    }
  })

  isSplit = function(pins) {
    if (!pins) { return false }
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

  pinsKnocked = function(pins) {
    var all_pins = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]

    return all_pins.filter(function(pin) { return !pins.includes(pin) })
  }

  updateTenthFallenPins = function() {
    var toss = $(".shot.current")
    var shot_idx = shotIndex(toss)

    // Always knock the current pins down
    knockPinsForShot(toss, "fallen")

    if (shot_idx == 1) {
      if (currentTossAtIdx(0).val() != "X") {
        knockPinsForShot(currentTossAtIdx(0), "fallen-before")
      }
    } else if (shot_idx == 2) {
      if (currentTossAtIdx(1).val() != "X" && currentTossAtIdx(1).val() != "/") {
        knockPinsForShot(currentTossAtIdx(1), "fallen-before")
      }
    }
  }

  knockPinsForShot = function(shot, klass) {
    var pins_kept = fallenPinsForShot(shot).val()
    $(".pin-wrapper").removeClass(klass)

    if (pins_kept) {
      var pins = JSON.parse(pins_kept)
      var knocked = pinsKnocked(pins)
      knocked.forEach(function(pin) {
        $(".pin-wrapper[data-pin-num=" + pin + "]").addClass(klass)
      })
    } else {
      if (!$(".pin-all-toggle").hasClass("fall")) {
        $(".pin-wrapper").addClass("fallen")
      }
    }
  }

  updateFallenPins = function() {
    var toss = $(".shot.current")

    if (toss.parents(".frame").attr("data-frame") == "10") { return updateTenthFallenPins() }

    var prev_shot = toss.parents(".frame").find(".shot[data-shot-idx=" + (parseInt(toss.attr("data-shot-idx")) - 1) + "]")

    knockPinsForShot(prev_shot, "fallen-before")
    knockPinsForShot(toss, "fallen")
    if ($(".fallen").length == 0) { clearTimeout(pinTimer) }
  }

  currentTossAtIdx = function(idx) {
    return $(".shot.current").parents(".frame").find(".shot[data-shot-idx=" + idx + "]")
  }

  resetPinTimer = function() {
    clearTimeout(pinTimer)
    if (!$(".timer-toggle").hasClass("active")) {
      spinner.reset()
      return
    }

    spinner.start()
    pinTimer = setTimeout(function() {
      if ($(".timer-toggle").hasClass("active")) { $(".next-frame").click() }
    }, timer_duration)
    // timer-toggle
  }

  recountPins = function() {
    clearTimeout(pinTimer)
    var toss = $(".shot.current")
    var pins = $(".pin-wrapper:not(.fallen, .fallen-before)").map(function() {
      return parseInt($(this).attr("data-pin-num"))
    }).toArray()
    var first_throw = (shotIndex(toss) == 0 || (shotIndex(toss) == 1 && currentTossAtIdx(0).attr("data-score") == 10))

    if (first_throw && isSplit(pins)) {
      toss.parents(".split-holder").addClass("split")
    } else {
      toss.parents(".split-holder").removeClass("split")
    }

    // Store the pins that are still standing in the current throw
    toss.parents(".frame").find(".fallen-pins[data-shot-idx=" + toss.attr("data-shot-idx") + "]").val("[" + pins.join() + "]")
    addScore($(".pin-wrapper.fallen:not(.fallen-before)").length, true)
    // If pins have changed, knock down the ones for the next throw as well
    if (first_throw) {
      var next_fallen = toss.parents(".frame").find(".fallen-pins[data-shot-idx=" + (shotIndex(toss) + 1) + "]")
      if (next_fallen.val().length > 0) {
        var next_pins = JSON.parse(next_fallen.val()).filter(function(pin) {
          return pins.includes(pin)
        })

        next_fallen.val("[" + next_pins.join() + "]")
        var next_shot = toss.parents(".frame").find(".shot[data-shot-idx=" + (shotIndex(toss) + 1) + "]")
        addScore(pins.length - next_pins.length, true, next_shot)
      }
    }

    recalculateFrame(toss)
    calcScores()
  }

  fillRandomScores = function() {
    var hold = should_check_stats
    should_check_stats = false
    while($(".shot.current").length > 0) {
      addScore(Math.floor(Math.random() * 11))
    }
    should_check_stats = hold
  }

  $(document).on("click", ".shot", function() {
    moveToThrow($(this))
    $(this).blur()
  }).on("click", ".bowling-navigation .nav-buttons", function(evt) {
    var btn = $(this)
    var input = $(".bowling-input")
    var left = input.hasClass("left")
    var right = input.hasClass("right")

    if (btn.hasClass("left")) {
      if (left) {
        input.removeClass("left").addClass("right")
      } else if (right) {
        input.removeClass("right")
      } else {
        input.addClass("left")
      }
    } else if (btn.hasClass("right")) {
      if (right) {
        input.removeClass("right").addClass("left")
      } else if (left) {
        input.removeClass("left")
      } else {
        input.addClass("right")
      }
    }
  })

  $("form.bowling-game-form").submit(function(evt) {
    evt.preventDefault()

    if (inProgress) {
      if (!confirm("The game is not complete. Are you sure you want to continue?")) {
        return false
      }
    }
    if ($(".card-point").length == 0 && $(".bowler").length > 1) {
      if (!confirm("You did not enter a winner for cards. Are you sure you want to continue?")) {
        return false
      }
    }

    $(".bowling-form-btn").val("Saving...")

    var form = $(this)
    $.ajax({
      type: form.attr("method"),
      url: form.attr("action"),
      data: form.serialize()
    }).done(function(data) {
      window.location.href = data.redirect
    }).fail(function() {
      $(".bowling-form-btn").html("Try Again")
    })
  })

  $(".bowling-input .numpad-key.entry").click(function() {
    $(".pin-wrapper").removeClass("fallen").removeClass("fallen-before")
    $(".shot.current").parents(".frame").find(".fallen-pins").val("")
    addScore($(this).text())
  })

  $(".bowling-cell.total .remove").click(function() {
    $(this).parents(".bowling-table").remove()
  })

  $(".backspace").click(function() {
    backspace()
  })

  $(document).on("click", ".bowler-name", function() {
    if ($(this).find(".card-point").length > 0) {
      $(".card-point-field").val(false)
      $(".card-point").remove()
    } else {
      $(".card-point-field").val(false)
      $(".card-point").remove()
      var card = $("<div>").addClass("card-point").text("+1")
      $(this).append(card)
      $(this).parent().find(".card-point-field").val(true)
    }
  })

  $(document).keyup(function(evt) {
    if (/[0-9\/\+\-]/i.test(evt.key)) {
      var num = evt.key == "+" ? "X" : evt.key
      addScore(num)
    } else if (evt.key == "Backspace" || evt.key == "Delete") {
      backspace()
    }
  })

  resetPinFall = function() {
    if (!$(".pin-all-toggle").hasClass("fall")) {
      $(".pin-wrapper").addClass("fallen").removeClass("fallen-before")
    }
  }

  throwScore = function(text) {
    var score = text
    score = score == "" ? null : parseInt(score)
    return isNaN(score) ? null : score
  }

  collectThrows = function(bowler, include_perfect) {
    return $(bowler).find(".bowling-cell.frame").map(function() {
      var frame = $(this)
      return [$(this).find(".shot").map(function() {
        var score = throwScore($(this).attr("data-score"))

        if (include_perfect && score == null) {
          var shot_idx = frame.find(".shot").index($(this))
          if (shot_idx > 0) {
            var prev_throw = $(frame.find(".shot")[shot_idx - 1])

            if (shot_idx == 2) { // Tenth frame, 3rd throw
              var first_throw = $(frame.find(".shot")[0])
              var first_open = first_throw.val() && first_throw.val() != "/" && first_throw.val() != "X"
              var second_open = prev_throw.val() && prev_throw.val() != "/" && prev_throw.val() != "X"
              if (first_open && second_open) {
                score = null
                return
              }
            }
            if (prev_throw.val() != "/" && prev_throw.val() != "X") {
              var prev_score = throwScore(prev_throw.attr("data-score"))
              score = 10 - prev_score
            } else if (frame.attr("data-frame") == "10") {
              score = 10
            } else {
              score = null
            }
          } else {
            score = 10
          }
        }

        return score
      }).toArray()]
    }).toArray()
  }

  sumScores = function(arr) {
    return arr.reduce(function(a, b) {
      return parseInt(a) + parseInt(b)
    }, 0)
  }

  calcFrameScores = function(score_array) {
    var running_total = 0
    var still_calc = true

    return score_array.map(function(tosses, idx) {
      var frame_total = 0
      var first = tosses[0]
      var second = tosses[1]

      if (first == null) { still_calc = false }
      if (idx == 9) { // Tenth frame
        frame_total = sumScores(tosses)
      } else if (first == 10) { // Strike
        var next_tosses = score_array[idx + 1]
        if (next_tosses[0] == 10) { // Next frame is also a strike
          var more_tosses = score_array[idx + 2] || []
          next_tosses = next_tosses.concat(more_tosses)
        }
        frame_total = 10 + sumScores(next_tosses.slice(0, 2))
      } else if (first + second == 10) { // Spare
        var next_tosses = score_array[idx + 1] || []
        frame_total = 10 + sumScores(next_tosses.slice(0, 1))
      } else { // Open frame
        frame_total = sumScores(tosses)
      }

      if (still_calc) {
        return running_total += frame_total
      }
    })
  }

  recalcScores = function() {
    var low_frame = 10
    $(".bowling-table.bowler:not(.absent, .skip)").each(function() {
      var bowler = $(this)
      var frames = bowler.find(".bowling-cell.frame")
      frames.each(function() {
        var toss = $(this).find(".shot").first()
        if (toss.val() != "") {
          recalculateFrame(toss)
          var frame_pos = parseInt(toss.attr("data-frame"))
          if (low_frame < frame_pos) { low_frame = frame_pos }
        }
      })
    })

    calcScores()
    moveToNextFrame()
  }

  calcScores = function() {
    var team_total = 0
    var team_hdcp = 0
    var frame_num = findCurrentFrame()

    $(".bowling-table.bowler").each(function(bowler_idx) {
      var bowler = $(this)
      var absent = bowler.hasClass("absent")
      var frames = bowler.find(".bowling-cell.frame")

      if (absent) {
        var absent_score = parseInt(bowler.attr("data-absent-score"))
        var absent_frame_score = Math.floor(absent_score / 10)
        var current_final_score = absent_frame_score * frame_num
        if (frame_num == 10) { current_final_score = absent_score }
        var max_final_score = absent_score

        frames.toArray().forEach(function(frame, idx) {
          if (idx + 1 > frame_num) {
            $(frame).find(".score").text("")
          } else if (idx == 9) { // Tenth frame
            $(frame).find(".score").text(max_final_score)
          } else {
            $(frame).find(".score").text(absent_frame_score * (idx + 1))
          }
        })
      } else {
        var current_game = calcFrameScores(collectThrows(bowler))
        var max_game = calcFrameScores(collectThrows(bowler, true))

        var squished_game = current_game.filter(function(score) { return score !== undefined })
        var current_final_score = squished_game[squished_game.length - 1] || 0
        var max_final_score = max_game[max_game.length - 1]

        current_game.forEach(function(frame_score, idx) {
          $(frames[idx]).find(".score").text(frame_score)
        })
      }

      bowler.find(".total").find(".max").text("(max: " + max_final_score + ")")
      team_hdcp += parseInt(bowler.find(".total").find(".hdcp").attr("data-base") || 0)
      bowler.find(".total").find(".hdcp").text(function() {
        if ($(this).attr("data-base")) {
          return (parseInt($(this).attr("data-base")) || 0) + current_final_score
        }
      })
      bowler.find(".total").find(".score").val(current_final_score)
      team_total += current_final_score
    })
    var total_text = team_total
    if (team_hdcp > 0) {
      total_text = total_text + "|" + (team_total + team_hdcp)
    }
    $(".team-total").text(total_text)

    inProgress = findCurrentFrame() < 11
    if (findCurrentFrame() > 1 && !inProgress) {
      $(".bowling-form-btn").removeClass("hidden")
    }
  }

  recalculateFrame = function(toss) {
    var frame = toss.parents(".frame")
    var shots = frame.find(".shot")

    var first_shot = $(shots[0])
    var sec_shot = $(shots[1])

    if (frame.attr("data-frame") == 10) {
      shots.each(function(idx) {
        if ($(this).val() == "") {
          $(this).removeAttr("data-score")
        } else if ($(this).val() == "/") {
          $(this).attr("data-score", 10 - shotScore(shots[idx - 1]))
        } else {
          $(this).attr("data-score", shotScore(this))
        }
      })
    } else {
      if (first_shot.val() == "X") {
        shots.val("").removeAttr("data-score")
        first_shot.val("X").attr("data-score", 10)
      } else if (sec_shot.val() == "/") {
        var first_score = shotScore(first_shot)
        first_shot.val(first_score || "-").attr("data-score", first_score)
        sec_shot.val("/").attr("data-score", 10 - first_score)
      } else {
        shots.each(function() {
          if ($(this).val() == "") {
            $(this).removeAttr("data-score")
          } else {
            $(this).attr("data-score", shotScore(this))
          }
        })
      }
    }
  }

  backspace = function() {
    var toss = $(".shot.current")
    var frame = toss.parents(".frame")
    var shots = frame.find(".shot")
    var shot_idx = shots.index(toss)

    if (shot_idx == 0) {
      strikePoint(null)
      shots.each(function() { clearShot(this) })
    } else {
      clearShot(toss)
    }

    updateFallenPins()
    calcScores()
  }

  shotIndex = function(shot) {
    var shot_idx = shot.attr("data-shot-idx")

    return parseInt(shot_idx)
  }

  moveToEarliestThrow = function() {
    var toss = $(".shot.current")
    var earliest_empty_shot = toss.parents(".frame").find(".shot").filter(function() {
      return !this.value
    }).first()

    if (shotIndex(earliest_empty_shot) < shotIndex(toss)) {
      $(".shot.current").removeClass("current")
      toss = earliest_empty_shot.addClass("current")
    }
  }

  addScore = function(text, stay, toss) {
    stay = stay || false
    toss = toss || $(".shot.current")

    moveToEarliestThrow()

    if (currentFrame() == 10) { return addTenthFrameScore(text, stay, toss) }

    var score = textToScore(text)
    var prev_shot = $(toss.parents(".frame").find(".shot")[0])
    var actual_val = scoreToVal(score, shotScore(prev_shot))
    toss.attr("data-score", actual_val)

    var shot_num = shotIndex(toss) + 1

    if (shot_num == 1) {
      if (score >= 10) {
        toss.parents(".frame").find(".shot").val("") // Clear second shot
        toss.val("X")
        recalculateFrame(toss)
        if (!stay) { moveToNextFrame() }
      } else {
        toss.val(score == "0" ? "-" : score)
        recalculateFrame(toss)
        if (!stay) { moveToNextThrow() }
      }
    } else if (shot_num == 2) {
      if (prev_shot.val() == "X") {
        if (!stay) { moveToNextFrame() }
      }
      // If first shot is blank, add score to first frame instead
      if (prev_shot.val() == "") {
        toss.removeAttr("data-score")
        moveToThrow(prev_shot)
        return addScore(score)
      }

      if (score + shotScore(prev_shot) >= 10) {
        toss.val("/")
      } else {
        toss.val(score == "0" ? "-" : score)
      }

      recalculateFrame(toss)
      if (!stay) { moveToNextFrame() }
    }
  }

  minMax = function(a, b, c) {
    return [a, b, c].sort(function(x, y) { return x - y })[1]
  }

  scoreToVal = function(score, prev_score) {
    prev_score = parseInt(prev_score) || 0
    score = minMax(0, 10 - prev_score, textToScore(score))

    if (!isNaN(score)) { return score }
    if (score == "-") { return 0 }
    if (score == "X") { return 10 }
    if (score == "/") { return 10 - prev_score }
    return 0
  }

  textToScore = function(text) {
    if (text == "-") { return 0 }
    if (text == "/") { return 10 }
    if (text == "X") { return 10 }

    return text == "" || isNaN(text) ? 0 : parseInt(text)
  }

  addTenthFrameScore = function(score, stay, toss) {
    stay = stay || false
    toss = toss || $(".shot.current")
    var shot_num = shotIndex(toss) + 1
    var toss_score = textToScore(score)
    var shots = toss.parents(".frame").find(".shot")
    var prev_shot = $(shots[shot_num - 2])
    var prev_score = shotScore(prev_shot)
    var actual_val = 0

    if (prev_shot.val() == "X" || prev_shot.val() == "/") {
      actual_val = scoreToVal(score, 0) // After a close in the 10th, acts as a new frame
    } else {
      actual_val = scoreToVal(score, prev_score)
    }
    toss.attr("data-score", actual_val)

    if (prev_shot.length > 0 && prev_score < 10 && prev_score + toss_score >= 10) {
      toss.val("/")
      if (!stay) { moveToNextThrow() }
    } else if (toss_score >= 10) {
      toss.val("X")
      if (!stay) { moveToNextThrow() }
    } else {
      toss.val(score == "0" ? "-" : score)

      if (!stay) {
        if (shot_num == 1 || prev_score >= 10) { return moveToNextThrow() }
        moveToNextFrame()
      }
    }
  }

  currentFrame = function() {
    var toss = $(".shot.current")
    var frame = toss.parents(".frame")

    return parseInt(frame.attr("data-frame"))
  }

  currentThrowNum = function() {
    var toss = $(".shot.current")
    var frame = toss.parents(".frame")
    var shots = frame.find(".shot")

    return shots.index(toss) + 1
  }

  moveToThrow = function(toss) {
    $(".shot.current").removeClass("current")
    toss.addClass("current")
    clearTimeout(pinTimer)
    resetPinFall()
    resetStrikePoint()
    checkStats()
    updateFallenPins()
  }

  checkStats = function() {
    var stats = $(".stats-holder")
    stats.html("")

    if (!pin_mode_show || !should_check_stats) { return }

    var toss = $(".shot.current")
    if (toss.length == 0) { return }

    var bowler_id = toss.parents(".bowler").attr("data-bowler-id")
    if (bowler_id.length == 0) { return }

    var shotIdx = shotIndex(toss)
    var first_throw = shotIdx == 0
    if (currentFrame() == 10) {
      first_throw = first_throw || (shotIdx == 1 && currentTossAtIdx(0).attr("data-score") == 10)
      first_throw = first_throw || (shotIdx == 2 && currentTossAtIdx(1).attr("data-score") == 10 || currentTossAtIdx(1).val() == "/")
    }

    var url = stats.attr("data-stats-url")

    var pins
    if (first_throw) {
      pins = undefined
    } else {
      pins = fallenPinsForShot(currentTossAtIdx(shotIndex(toss) - 1)).val()
    }

    stats.html("<i class=\"fa fa-spinner fa-spin\"></i>")

    $.get(url, { bowler_id: bowler_id, pins: pins }).done(function(data) {
      stats.html("")
      if (!data.stats.total) { return }
      var nums = data.stats.spare + " / " + data.stats.total
      var ratio = Math.round((data.stats.spare / data.stats.total) * 100)

      $(".stats-holder").html(ratio + "%" + "</br>" + nums)
    })
  }

  moveToNextThrow = function() {
    calcScores()
    var next_shot = currentTossAtIdx(parseInt($(".shot.current").attr("data-shot-idx")) + 1)

    if (next_shot.length > 0) {
      moveToThrow(next_shot)
    } else {
      moveToNextFrame()
    }
  }

  findNextFrame = function(bowler) {
    return bowler.find('.shot[data-shot-idx="0"]').filter(function() {
      return !$(this).val()
    }).first().parents(".frame")
  }

  findCurrentFrame = function() {
    setFrames()
    return Math.min.apply(Math, $(".bowler:not(.absent, .skip)").map(function() {
      return parseInt($(this).attr("data-current-frame")) || 0
    }))
  }

  setFrames = function() {
    $(".bowling-table.bowler:not(.absent, .skip)").each(function() {
      var bowler = $(this)
      var current_frame = findNextFrame(bowler)

      bowler.attr("data-current-frame", current_frame.attr("data-frame") || 11)
    })
  }

  gotoNextFrame = function() {
    setFrames()

    var next_bowler = $(".bowling-table.bowler:not(.absent, .skip)").sort(function(a, b) {
      a = $(a)
      b = $(b)
      var a_frame = parseInt(a.attr("data-current-frame"))
      var b_frame = parseInt(b.attr("data-current-frame"))

      if (a_frame == b_frame) {
        var a_bowler = parseInt(a.attr("data-bowler"))
        var b_bowler = parseInt(b.attr("data-bowler"))
        return a_bowler - b_bowler
      }

      return a_frame - b_frame
    }).first()

    moveToThrow(findNextFrame(next_bowler).find(".shot").first())
  }

  shotScore = function(toss) {
    var score = $(toss).val()

    return textToScore(score)
  }

  gotoNextPlayer = function() {
    calcScores()
    $(".shot.current").removeClass("current")
  }

  moveToNextFrame = function() {
    calcScores()
    // If there are more players, should go to next bowler
    if ($(".shot.current").parents(".frame").attr("data-frame") == "10") {
      var frame_shots = $(".shot.current").parents(".frame").find(".shot")
      if (shotScore(frame_shots[0]) + shotScore(frame_shots[1]) >= 10) {
        if (currentThrowNum() < 3) { return moveToNextThrow() }
      }
    }
    gotoNextFrame()
  }

  $(".shot").filter(function() {
    return !this.value
  }).first().addClass("current")
  setFrames() // Need this to set absent bowlers
  recalcScores()
})
