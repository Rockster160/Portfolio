$(".ctr-bowlings.act-show").ready(function() {
  $(".throw").click(function() {
    moveToThrow($(this))
  })

  $(".bowling-input td").click(function() {
    addScore($(this).text())
  })

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
    $(".throw.current").removeClass("current")
  }

  function moveToNextFrame() {
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
