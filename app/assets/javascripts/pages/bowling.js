$(".ctr-bowlings.act-show").ready(function() {
  $(".throw").click(function() {
    moveToThrow($(this))
  })

  $(".bowling-input td").click(function() {
    addScore($(this).text())
  })

  function collectThrows(player) {
    return $(player).children(".bowling-cell.frame").map(function() {
      return [$(this).children(".throw").text().split("")]
    })
  }

  function sumScores(arr) {
    return arr.reduce(function(a, b) {
      return textToScore(a) + textToScore(b)
    }, 0)
  }

  function calcScores() {
    $(".bowling-table").each(function() {
      var player = $(this)
      var throws = collectThrows(player)
      var frames = player.children(".bowling-cell.frame")
      var running_total = 0
      var still_calc = true
      var max_score = 0
      var current_frame = currentFrame()

      throws.each(function(idx) {
        var frame_total = 0
        var tosses = this
        var first = tosses[0]
        var second = tosses[1]

        if (!first) { return still_calc = false }
        if (current_frame == 10 && idx == 9) {
          frame_total = sumScores(tosses)
        } else if (first == "X") {
          var next_tosses = throws[idx + 1] || []
          if (next_tosses[0] == "X") {
            var more_tosses = throws[idx + 2] || []
            next_tosses = next_tosses.concat(more_tosses)
          }
          if (next_tosses.length < 2) { return still_calc = false }
          frame_total = 10 + sumScores(next_tosses.slice(0, 2))
        } else if (second == "/") {
          var next_tosses = throws[idx + 1] || []
          if (next_tosses.length < 1) { return still_calc = false }
          frame_total = 10 + sumScores(next_tosses.slice(0, 1))
        } else {
          frame_total = sumScores(tosses)
        }

        running_total += frame_total
        var score_holder = $(frames[idx]).children(".score")
        score_holder.attr("data-frame-score", frame_total)
        score_holder.text(running_total)
      })
    })
  }

  function addScore(text) {
    if (currentFrame() == 10) { return addTenthFrameScore(text) }

    var score = textToScore(text)
    var toss = $(".throw.current")
    var throw_num = currentThrowNum()

    if (throw_num == 1) {
      if (score >= 10) {
        toss.text("X")
        moveToNextFrame()
      } else {
        toss.text(score == "0" ? "-" : score)
        moveToNextThrow()
      }
    } else if (throw_num == 2) {
      var prev_throw = $($(".throw.current").parent(".frame").children(".throw")[0])
      // If first throw is blank, add score to first frame instead
      if (prev_throw.text() == "") {
        moveToThrow(prev_throw)
        return addScore(score)
      }

      if (score + throwScore(prev_throw) >= 10) {
        toss.text("/")
      } else {
        toss.text(score == "0" ? "-" : score)
      }

      moveToNextFrame()
    }
  }

  function textToScore(text) {
    if (text == "-") { return 0 }
    if (text == "/") { return 10 }
    if (text == "X") { return 10 }

    return text == "" || isNaN(text) ? 0 : parseInt(text)
  }

  function addTenthFrameScore(score) {
    var throw_num = currentThrowNum()
    var toss = $(".throw.current")
    var toss_score = textToScore(score)
    var throws = toss.parent().children(".throw")
    var prev_throw = $(throws[throw_num - 2])
    var prev_score = throwScore(prev_throw)

    if (prev_throw.length > 0 && prev_score < 10 && prev_score + toss_score >= 10) {
      toss.text("/")
      moveToNextThrow()
    } else if (toss_score >= 10) {
      toss.text("X")
      moveToNextThrow()
    } else {
      toss.text(score == "0" ? "-" : score)

      if (throw_num == 1 || prev_score >= 10) { return moveToNextThrow() }
      moveToNextFrame()
    }
  }

  function currentFrame() {
    var toss = $(".throw.current")
    var frame = toss.parent()

    return parseInt(frame.attr("data-frame"))
  }

  function currentThrowNum() {
    var toss = $(".throw.current")
    var frame = toss.parent()
    var throws = frame.children(".throw")

    return throws.index(toss) + 1
  }

  function moveToThrow(toss) {
    $(".throw.current").removeClass("current")
    toss.addClass("current")
  }

  function moveToNextThrow() {
    calcScores()
    var next_throw = $(".throw.current").next(".throw")

    if (next_throw.length > 0) {
      moveToThrow(next_throw)
    } else {
      moveToNextFrame()
    }
  }

  function gotoNextFrame() {
    var next_frame = $(".throw.current").parent().next(".frame")

    moveToThrow(next_frame.children(".throw").first())
  }

  function throwScore(toss) {
    var score = $(toss).text()

    return textToScore(score)
  }

  function gotoNextPlayer() {
    calcScores()
    $(".throw.current").removeClass("current")
  }

  function moveToNextFrame() {
    calcScores()
    // If there are more players, should go to next player
    if ($(".throw.current").parent().attr("data-frame") == "10") {
      var frame_throws = $(".throw.current").parent(".frame").children(".throw")
      if (throwScore(frame_throws[0]) + throwScore(frame_throws[1]) >= 10) {
        if (currentThrowNum() < 3) { return moveToNextThrow() }
      }

      gotoNextPlayer()
    } else {
      gotoNextFrame()
    }
  }
})
