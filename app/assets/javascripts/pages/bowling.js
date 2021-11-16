// 65 unique combinations of shots per frame
// 4300 possible games (65*65 + 10th frame weirdness)
$(".ctr-bowlings.act-show").ready(function() {

  $(".shot").first().addClass("current")

  $(".shot").click(function() {
    moveToThrow($(this))
  })

  $(".bowling-input td").click(function() {
    addScore($(this).text())
  })

  $(document).keyup(function(evt) {
    if (/[0-9\/\+]/i.test(evt.key)) {
      var num = evt.key == "+" ? "X" : evt.key
      addScore(num)
    }
  })

  function collectThrows(bowler) {
    return $(bowler).children(".bowling-cell.frame").map(function() {
      return [$(this).children(".shot").map(function() {
        var score = $(this).attr("data-score")
        score = score == "" ? null : parseInt(score)
        score = isNaN(score) ? null : score
        return score
      }).toArray()]
    }).toArray()
  }

  function sumScores(arr) {
    return arr.reduce(function(a, b) {
      return parseInt(a) + parseInt(b)
    }, 0)
  }

  function calcScores() {
    $(".bowling-table.bowler").each(function() {
      var bowler = $(this)
      var shots = collectThrows(bowler)
      var frames = bowler.children(".bowling-cell.frame")
      var running_total = 0
      var still_calc = true
      // var max_score = 0

      shots.forEach(function(tosses, idx) {
        if (!still_calc) { return }
        var frame_total = 0
        var first = tosses[0]
        var second = tosses[1]

        if (first == null) { return still_calc = false }
        if (idx == 9) { // Tenth frame
          frame_total = sumScores(tosses)
        } else if (first == 10) {
          var next_tosses = shots[idx + 1]
          if (next_tosses[0] == 10) {
            var more_tosses = shots[idx + 2] || []
            next_tosses = next_tosses.concat(more_tosses)
          }
          if (next_tosses.length < 2) { return still_calc = false }
          frame_total = 10 + sumScores(next_tosses.slice(0, 2))
        } else if (first + second == 10) {
          var next_tosses = shots[idx + 1] || []
          if (next_tosses.length < 1) { return still_calc = false }
          frame_total = 10 + sumScores(next_tosses.slice(0, 1))
        } else {
          frame_total = sumScores(tosses)
        }

        running_total += frame_total
        var score_holder = $(frames[idx]).children(".score")
        score_holder.text(running_total)
      })
    })
  }

  function recalculateFrame(toss) {
    var frame = toss.parent(".frame")
    var shots = frame.children(".shot")
    var shot_idx = shots.index(toss)
    var toss_score = shotScore(toss)

    var prev_shot = $(shots[shot_idx - 1])
    var prev_text = prev_shot.length > 0 ? prev_shot.text() : null
    var prev_val = shotScore(prev_shot)

    var next_shot = $(shots[shot_idx + 1])
    var next_text = next_shot.length > 0 ? next_shot.text() : null

    var actual_val = scoreToVal(toss.text(), !prev_shot ? 0 : prev_val)

    toss.attr("data-score", actual_val)

    if (toss.text() == "X") {
      toss.parent(".frame").children(".shot").text("").attr("data-score", "")
      toss.text("X").attr("data-score", 10)
    } else if (next_text == "/") {
      next_shot.text("/").attr("data-score", 10 - shotScore(toss))
    }

    // if (frame_num == "10") {
    // } else if (shot_idx == 0 && actual_val == 10) {
    //   toss.parent(".frame").children(".shot").text("").attr("data-score", "")
    //   toss.text("X").attr("data-score", 10)
    // } else if (shot_idx == 1 && prev_val + actual_val >= 10) {
    //   toss.text("/").attr("data-score", actual_val)
    // } else {
    //   toss.text()
    // }

    // if (actual_val == 10) {
    //   toss.text("X")
    // }
  }

  function addScore(text) {
    if (currentFrame() == 10) { return addTenthFrameScore(text) }

    var score = textToScore(text)
    var toss = $(".shot.current")
    var prev_shot = $(toss.parent(".frame").children(".shot")[0])
    var actual_val = scoreToVal(score, shotScore(prev_shot))
    toss.attr("data-score", actual_val)

    var shot_num = currentThrowNum()

    if (shot_num == 1) {
      if (score >= 10) {
        toss.parent(".frame").children(".shot").text("") // Clear second shot
        toss.text("X")
        recalculateFrame(toss)
        moveToNextFrame()
      } else {
        toss.text(score == "0" ? "-" : score)
        recalculateFrame(toss)
        moveToNextThrow()
      }
    } else if (shot_num == 2) {
      if (prev_shot.text() == "X") {
        moveToNextFrame()
      }
      // If first shot is blank, add score to first frame instead
      if (prev_shot.text() == "") {
        moveToThrow(prev_shot)
        return addScore(score)
      }

      if (score + shotScore(prev_shot) >= 10) {
        toss.text("/")
      } else {
        toss.text(score == "0" ? "-" : score)
      }

      recalculateFrame(toss)
      moveToNextFrame()
    }
  }

  function minMax(a, b, c) {
    return [a, b, c].sort(function(x, y) { return x - y })[1]
  }

  function scoreToVal(score, prev_score) {
    prev_score = parseInt(prev_score) || 0
    score = minMax(0, 10 - prev_score, textToScore(score))

    if (!isNaN(score)) { return score }
    if (score == "-") { return 0 }
    if (score == "X") { return 10 }
    if (score == "/") { return 10 - prev_score }
    return 0
  }

  function textToScore(text) {
    if (text == "-") { return 0 }
    if (text == "/") { return 10 }
    if (text == "X") { return 10 }

    return text == "" || isNaN(text) ? 0 : parseInt(text)
  }

  function addTenthFrameScore(score) {
    var shot_num = currentThrowNum()
    var toss = $(".shot.current")
    var toss_score = textToScore(score)
    var shots = toss.parent().children(".shot")
    var prev_shot = $(shots[shot_num - 2])
    var prev_score = shotScore(prev_shot)
    var actual_val = 0

    if (prev_shot.text == "X" || prev_shot.text == "/") {
      actual_val = scoreToVal(score, prev_score)
    } else {
      actual_val = scoreToVal(score, 0) // After a close in the 10th, acts as a new frame
    }
    toss.attr("data-score", actual_val)

    if (prev_shot.length > 0 && prev_score < 10 && prev_score + toss_score >= 10) {
      toss.text("/")
      moveToNextThrow()
    } else if (toss_score >= 10) {
      toss.text("X")
      moveToNextThrow()
    } else {
      toss.text(score == "0" ? "-" : score)

      if (shot_num == 1 || prev_score >= 10) { return moveToNextThrow() }
      moveToNextFrame()
    }
  }

  function currentFrame() {
    var toss = $(".shot.current")
    var frame = toss.parent()

    return parseInt(frame.attr("data-frame"))
  }

  function currentThrowNum() {
    var toss = $(".shot.current")
    var frame = toss.parent()
    var shots = frame.children(".shot")

    return shots.index(toss) + 1
  }

  function moveToThrow(toss) {
    $(".shot.current").removeClass("current")
    toss.addClass("current")
  }

  function moveToNextThrow() {
    calcScores()
    var next_shot = $(".shot.current").next(".shot")

    if (next_shot.length > 0) {
      moveToThrow(next_shot)
    } else {
      moveToNextFrame()
    }
  }

  function findNextFrame(bowler) {
    return bowler.find(".shot:first-of-type:empty").first().parent()
  }

  function gotoNextFrame() {
    $(".bowling-table.bowler").each(function() {
      var bowler = $(this)
      var current_frame = findNextFrame(bowler)

      bowler.attr("data-current-frame", current_frame.attr("data-frame") || 11)
    })

    var next_bowler = $(".bowling-table.bowler").sort(function(a, b) {
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

  function shotScore(toss) {
    var score = $(toss).text()

    return textToScore(score)
  }

  function gotoNextPlayer() {
    calcScores()
    $(".shot.current").removeClass("current")
  }

  function moveToNextFrame() {
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
})
