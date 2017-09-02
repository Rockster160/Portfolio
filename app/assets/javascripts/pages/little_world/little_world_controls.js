var seed = 3141;
function random() {
  var x = Math.sin(seed++) * 10000;
  return x - Math.floor(x);
}
function randRange(start, end) {
  return Math.round(start + (random() * (end - start)));
}

$('.ctr-little_worlds.act-show').ready(function() {
  $(".little-world-wrapper").disableSelection()

  var ticksPerMovementFrame = 5
  var lastBlockHoveredCoord = [];
  var screenMessage;
  var chatBoxTimer
  currentPlayer = new Player($(".player"))
  littleWorld = new LittleWorld()
  littleWorldPlayers.push(currentPlayer)

  setupLittleWorldChannel()

  screenLog = function() {
    var playerCoord = currentPlayer.currentCoord()
    $(".screen-log .player-coord").html(playerCoord[0] + ", " + playerCoord[1])
    if (lastBlockHoveredCoord.length == 2) {
      $(".screen-log .block-coord").html(lastBlockHoveredCoord[0] + ", " + lastBlockHoveredCoord[1])
    } else {
      $(".screen-log .block-coord").html("N/A")
    }
    $(".screen-log .message").html(screenMessage)
  }

  actOnKeysPressed = function() {
    if (isKeyPressed(keyEvent("SPACE"))) {
      scrollToPlayer()
    }
    if (isKeyPressed(keyEvent("J")) && lastBlockHoveredCoord.length == 2) {
      currentPlayer.path = []
      currentPlayer.jumpTo(lastBlockHoveredCoord)
    }
  }

  nowStamp = function() {
    return (new Date()).getTime();
  }

  postDestination = function() {
    var timestamp = nowStamp()
    if (timestamp < currentPlayer.lastMoveTimestamp) { return }
    var coord = currentPlayer.destination
    try { coord[0] } catch(err) { debugger }
    var url = $("[data-save-location-url]").attr("data-save-location-url")
    var params = { avatar: { location_x: coord[0], location_y: coord[1], timestamp: timestamp } }
    currentPlayer.lastMoveTimestamp = timestamp
    $.post(url, params)
  }

  scrollToPlayer = function() {
    if (!canCameraChange) { return }
    canCameraChange = false

    var maxScrollSpeed = 5 * ticksPerMovementFrame // px per movement frame == px per 100 ticks
    var playerPos = currentPlayer.html.position()
    var startLeft = $(window).scrollLeft(), newLeft = playerPos.left - ($(window).width() / 2) + (littleWorld.blockWidth / 2)
    var startTop = $(window).scrollTop(), newTop = playerPos.top - ($(window).height() / 2)

    scrollLeftDiff = newLeft - startLeft
    if (scrollLeftDiff > maxScrollSpeed) { scrollLeftDiff = maxScrollSpeed }
    if (scrollLeftDiff < -maxScrollSpeed) { scrollLeftDiff = -maxScrollSpeed }

    scrollTopDiff = newTop - startTop
    if (scrollTopDiff > maxScrollSpeed) { scrollTopDiff = maxScrollSpeed }
    if (scrollTopDiff < -maxScrollSpeed) { scrollTopDiff = -maxScrollSpeed }

    $("body, html").stop().animate({
      scrollLeft: startLeft + scrollLeftDiff,
      scrollTop: startTop + scrollTopDiff
    }, {
      duration: ticksPerMovementFrame,
      complete: function() {
        canCameraChange = true
      }
    })
  }

  tick = function() {
    screenLog()
    Player.tick()
  }

  triggerEvent = function(key, direction) {
    switch(key) {
      case keyEvent("SPACE"):
      case keyEvent("J"):
        if (direction == "up") {
          multiKeyUp(key)
        } else if (direction == "down") {
          multiKeyDown(key)
        }
        return true
      break;
    }
    return false
  }

  showChatBox = function() {
    $(".chat-box").stop()
    $(".chat-box").css({opacity: 0.7})
    $(".chat-box").removeClass("hidden")
    $(".open-chat-btn").addClass("hidden")
    clearTimeout(chatBoxTimer)
  }
  hideChatBox = function(delay, duration) {
    delay = delay || 5000
    duration = duration || 1000
    $(".open-chat-btn").stop()
    $(".chat-box").stop()
    $(".open-chat-btn").css("opacity", 0).removeClass("hidden")
    clearTimeout(chatBoxTimer)
    chatBoxTimer = setTimeout(function() {
      $(".chat-box").animate({
        opacity: 0
      }, {
        duration: duration,
        complete: function() { $(".chat-box").addClass("hidden").css("opacity", 0.7) }
      })
      $(".open-chat-btn").animate({ opacity: 1 }, duration)
    }, delay)
  }

  $(document).keyup(function(evt) {
    if ($(".chat-input").is(":focus")) {
      if (evt.which == keyEvent("ENTER")) {
        if ($(".chat-input").val().length > 0) {
          App.little_world.speak($(".chat-input").val())
        }
        $(".chat-input").val("")
        $(".chat-input").blur()
      }
    } else if (evt.which == keyEvent("ENTER")) {
      showChatBox()
      $(".chat-input").focus()
    } else {
      if (triggerEvent(evt.which, "up")) {
        evt.preventDefault()
        return false
      }
    }
  }).keydown(function(evt) {
    if ($(".chat-input").is(":focus")) {
      if ($(".chat-input").val().length >= 256) {
        evt.preventDefault()
        return false
      }
    } else {
      if (triggerEvent(evt.which, "down")) {
        evt.preventDefault()
        return false
      }
    }
  })

  // var currentScrollPosition = 0;
  // $(document).scroll(function() {
  //   currentScrollPosition = $(".little-world-wrapper").scrollTop();
  // });

  $(".open-chat-btn").on("click tap touch", function() {
    showChatBox()
    $(".chat-input").focus()
    $(".chat-input").click()
  })
  $(".chat-input").on("blur mouseleave", hideChatBox)
  $(".chat-input").on("focus mouseover mouseenter", function() {
    // $(".little-world-wrapper").scrollTop(currentScrollPosition);
    showChatBox()
  })

  $('.block.walkable').on('mousedown tap touch', function(evt) {
    var newCoord = littleWorld.getCoordForBlock(this)
    currentPlayer.setDestination(newCoord);
  })

  $(".block[data-x][data-y]").mouseover(function() {
    lastBlockHoveredCoord = littleWorld.getCoordForBlock(this)
  })

  $(window).on('beforeunload', function() {
    $(window).scrollTop(0).scrollLeft(0);
  });

  setInterval(tick, 1);
  setInterval(actOnKeysPressed, 5);
  currentPlayer.logIn(false, function() {
    var playerPos = currentPlayer.html.position(), newLeft = playerPos.left - ($(window).width() / 2) + (littleWorld.blockWidth / 2), newTop = playerPos.top - ($(window).height() / 2);
    setTimeout(function() {
      $("body, html").stop().scrollLeft(newLeft).scrollTop(newTop)
    }, 200)
  })
})
