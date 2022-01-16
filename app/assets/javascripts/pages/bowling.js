$(".ctr-bowling_games.act-new, .ctr-bowling_games.act-edit").ready(function() {

  var editing = false
  $(".bowling-edit").click(function(evt) {
    editing = !editing
    resetEdits()

    $(this).text(editing ? "Done" : "Edit")

    evt.preventDefault()
    return false
  })

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

  $(".add-bowler").click(function(evt) {
    var template = $("template#bowling-game").clone().html()
    var name = prompt("Enter Name for new bowler")
    var new_bowler = $(template).insertBefore(".bowler-placeholder")
    var max = Math.max.apply(null, $("[data-bowler]").map(function() {
      return parseInt($(this).attr("data-bowler"))
    }))
    new_bowler.attr("data-bowler", max + 1)
    new_bowler.find(".game-position").val(max)
    new_bowler.find(".bowler-name .name").text(name)
    new_bowler.find(".bowler-name-field").val(name)

    resetEdits()

    evt.preventDefault()
    return false
  })

  $(".absent-checkbox").change(function() {
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

  fillRandomScores = function() {
    while($(".shot.current").length > 0) {
      addScore(Math.floor(Math.random() * 11))
    }
  }

  $(".shot").click(function() {
    moveToThrow($(this))
    $(this).blur()
  })

  $("form").submit(function(evt) {
    if ($(".card-point").length == 0) {
      if (!confirm("You did not enter a winner for cards. Are you sure you want to continue?")) {
        evt.preventDefault()
        return false
      }
    }
  })

  $(".bowling-input .numpad-key").click(function() {
    addScore($(this).text())
  })

  $(".bowling-cell.total .remove").click(function() {
    $(this).parents(".bowling-table").remove()
  })

  $(".bowler-name").click(function() {
    if ($(this).find(".card-point").length > 0) {
      $(".card-point-field").val(false)
      $(".card-point").remove()
    } else {
      $(".card-point-field").val(false)
      $(".card-point").remove()
      var card = $("<div>").addClass("card-point").text("+1")
      $(this).append(card)
      $(this).parent().children(".card-point-field").val(true)
    }
  })

  $(document).keyup(function(evt) {
    if (/[0-9\/\+\-]/i.test(evt.key)) {
      var num = evt.key == "+" ? "X" : evt.key
      addScore(num)
    } else if (evt.key == "Backspace" || evt.key == "Delete") {
      var toss = $(".shot.current")
      toss.val("")
      recalculateFrame(toss)
      calcScores()
    }
  })

  throwScore = function(text) {
    var score = text
    score = score == "" ? null : parseInt(score)
    return isNaN(score) ? null : score
  }

  collectThrows = function(bowler, include_perfect) {
    return $(bowler).children(".bowling-cell.frame").map(function() {
      var frame = $(this)
      return [$(this).children(".shot").map(function() {
        var score = throwScore($(this).attr("data-score"))

        if (include_perfect && score == null) {
          var shot_idx = frame.children(".shot").index($(this))
          if (shot_idx > 0) {
            var prev_throw = $(frame.children(".shot")[shot_idx - 1])

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
    $(".bowling-table.bowler:not(.absent)").each(function() {
      var bowler = $(this)
      var frames = bowler.find(".bowling-cell.frame")
      frames.each(function() {
        var toss = $(this).children(".shot").first()
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
      var frames = bowler.children(".bowling-cell.frame")

      if (absent) {
        var absent_score = parseInt(bowler.attr("data-absent-score"))
        var absent_frame_score = Math.floor(absent_score / 10)
        var current_final_score = absent_frame_score * frame_num
        if (frame_num == 10) { current_final_score = absent_score }
        var max_final_score = absent_score

        frames.toArray().forEach(function(frame, idx) {
          if (idx + 1 > frame_num) {
            $(frame).children(".score").text("")
          } else if (idx == 9) { // Tenth frame
            $(frame).children(".score").text(max_final_score)
          } else {
            $(frame).children(".score").text(absent_frame_score * (idx + 1))
          }
        })
      } else {
        var current_game = calcFrameScores(collectThrows(bowler))
        var max_game = calcFrameScores(collectThrows(bowler, true))

        var squished_game = current_game.filter(function(score) { return score !== undefined })
        var current_final_score = squished_game[squished_game.length - 1] || 0
        var max_final_score = max_game[max_game.length - 1]

        current_game.forEach(function(frame_score, idx) {
          $(frames[idx]).children(".score").text(frame_score)
        })
      }

      bowler.children(".total").children(".max").text("(max: " + max_final_score + ")")
      team_hdcp += parseInt(bowler.children(".total").children(".hdcp").attr("data-base") || 0)
      bowler.children(".total").children(".hdcp").text(function() {
        if ($(this).attr("data-base")) {
          return (parseInt($(this).attr("data-base")) || 0) + current_final_score
        }
      })
      bowler.children(".total").children(".score").val(current_final_score)
      team_total += current_final_score
    })
    var total_text = team_total
    if (team_hdcp > 0) {
      total_text = total_text + "|" + (team_total + team_hdcp)
    }
    $(".team-total").text(total_text)
  }

  recalculateFrame = function(toss) {
    var frame = toss.parent(".frame")
    var shots = frame.children(".shot")
    var shot_idx = shots.index(toss)
    var toss_score = shotScore(toss)

    var prev_shot = $(shots[shot_idx - 1])
    var prev_text = prev_shot.length > 0 ? prev_shot.val() : null
    var prev_val = shotScore(prev_shot)

    var next_shot = $(shots[shot_idx + 1])
    var next_text = next_shot.length > 0 ? next_shot.val() : null

    var actual_val = scoreToVal(toss.val(), !prev_shot ? 0 : prev_val)

    toss.attr("data-score", actual_val)

    if (toss.val() == "X") {
      toss.parent(".frame").children(".shot").val("").attr("data-score", "")
      toss.val("X").attr("data-score", 10)
    } else if (next_text == "/") {
      next_shot.val("/").attr("data-score", 10 - shotScore(toss))
    }
  }

  addScore = function(text) {
    if (currentFrame() == 10) { return addTenthFrameScore(text) }

    var score = textToScore(text)
    var toss = $(".shot.current")
    var prev_shot = $(toss.parent(".frame").children(".shot")[0])
    var actual_val = scoreToVal(score, shotScore(prev_shot))
    toss.attr("data-score", actual_val)

    var shot_num = currentThrowNum()

    if (shot_num == 1) {
      if (score >= 10) {
        toss.parent(".frame").children(".shot").val("") // Clear second shot
        toss.val("X")
        recalculateFrame(toss)
        moveToNextFrame()
      } else {
        toss.val(score == "0" ? "-" : score)
        recalculateFrame(toss)
        moveToNextThrow()
      }
    } else if (shot_num == 2) {
      if (prev_shot.val() == "X") {
        moveToNextFrame()
      }
      // If first shot is blank, add score to first frame instead
      if (prev_shot.val() == "") {
        moveToThrow(prev_shot)
        return addScore(score)
      }

      if (score + shotScore(prev_shot) >= 10) {
        toss.val("/")
      } else {
        toss.val(score == "0" ? "-" : score)
      }

      recalculateFrame(toss)
      moveToNextFrame()
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

  addTenthFrameScore = function(score) {
    var shot_num = currentThrowNum()
    var toss = $(".shot.current")
    var toss_score = textToScore(score)
    var shots = toss.parent().children(".shot")
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
      moveToNextThrow()
    } else if (toss_score >= 10) {
      toss.val("X")
      moveToNextThrow()
    } else {
      toss.val(score == "0" ? "-" : score)

      if (shot_num == 1 || prev_score >= 10) { return moveToNextThrow() }
      moveToNextFrame()
    }
  }

  currentFrame = function() {
    var toss = $(".shot.current")
    var frame = toss.parent()

    return parseInt(frame.attr("data-frame"))
  }

  currentThrowNum = function() {
    var toss = $(".shot.current")
    var frame = toss.parent()
    var shots = frame.children(".shot")

    return shots.index(toss) + 1
  }

  moveToThrow = function(toss) {
    $(".shot.current").removeClass("current")
    toss.addClass("current")
  }

  moveToNextThrow = function() {
    calcScores()
    var next_shot = $(".shot.current").next(".shot")

    if (next_shot.length > 0) {
      moveToThrow(next_shot)
    } else {
      moveToNextFrame()
    }
  }

  findNextFrame = function(bowler) {
    return bowler.find(".shot:first-of-type").filter(function() {
      return !this.value
    }).first().parent()
  }

  findCurrentFrame = function() {
    return Math.min.apply(Math, $(".bowler:not(.absent)").map(function() {
      return parseInt($(this).attr("data-current-frame")) || 0
    }))
  }

  gotoNextFrame = function() {
    $(".bowling-table.bowler:not(.absent)").each(function() {
      var bowler = $(this)
      var current_frame = findNextFrame(bowler)

      bowler.attr("data-current-frame", current_frame.attr("data-frame") || 11)
    })

    var next_bowler = $(".bowling-table.bowler:not(.absent)").sort(function(a, b) {
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

    moveToThrow(findNextFrame(next_bowler).children(".shot").first())
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
    if ($(".shot.current").parent().attr("data-frame") == "10") {
      var frame_shots = $(".shot.current").parent(".frame").children(".shot")
      if (shotScore(frame_shots[0]) + shotScore(frame_shots[1]) >= 10) {
        if (currentThrowNum() < 3) { return moveToNextThrow() }
      }
    }
    gotoNextFrame()
  }

  $(".shot").filter(function() {
    return !this.value
  }).first().addClass("current")
  recalcScores()
})
