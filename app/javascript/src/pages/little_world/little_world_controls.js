import { Player, LittleWorld } from "./player"
import { multiKeyDown, multiKeyUp, isKeyPressed } from "../../support/multi_key_detection"
import { little_world_sub } from "../../channels/little_world_channel"

var seed = 3141;
function random() {
  var x = Math.sin(seed++) * 10000;
  return x - Math.floor(x);
}
function randRange(start, end) {
  return Math.round(start + (random() * (end - start)));
}

$(document).ready(function() {
  if ($(".ctr-little_worlds.act-show").length == 0) { return }
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

  isMobile = function() {
    return /Android|webOS|iPhone|iPad|iPod|BlackBerry|IEMobile|Opera Mini/i.test(navigator.userAgent)
  }

  currentScroll = {}
  showInput = function() {
    showChatBox()
    $(".open-chat-btn").addClass("hidden")
    $(".chat-input").removeClass("hidden")
    currentScroll = {
      top: $("body").scrollTop(),
      left: $("body").scrollLeft()
    }
    $(".chat-input").focus()
    $(".chat-input").click()
    $("body").scrollTop(currentScroll.top)
    $("body").scrollLeft(currentScroll.left)
    if (isMobile()) { $(".chat-box").css("bottom", "50%") }
  }
  hideInput = function() {
    hideChatBox()
    $(".open-chat-btn").removeClass("hidden")
    $(".chat-input").addClass("hidden")
    if (isMobile()) { $(".chat-box").css("bottom", "5px") }
  }

  showChatBox = function() {
    $(".messages-container").stop()
    $(".messages-container").css({opacity: 1})
    $(".messages-container").removeClass("hidden")
    clearTimeout(chatBoxTimer)
  }
  hideChatBox = function(delay, duration) {
    delay = delay || 5000
    duration = duration || 1000
    $(".messages-container").stop()
    clearTimeout(chatBoxTimer)
    chatBoxTimer = setTimeout(function() {
      $(".messages-container").animate({
        opacity: 0
      }, {
        duration: duration + 1,
        complete: function() { $(".messages-container").addClass("hidden").css("opacity", 1) }
      })
    }, delay + 1)
  }

  $(".open-chat-btn").on("click tap touch", showInput)
  $(".chat-input").on("blur", hideInput)
  $(document).keyup(function(evt) {
    if ($(".chat-input").is(":focus")) {
      if (evt.which == keyEvent("ENTER")) {
        if ($(".chat-input").val().length > 0) {
          little_world_sub.speak($(".chat-input").val())
        }
        $(".chat-input").val("")
        $(".chat-input").blur()
      }
    } else if (evt.which == keyEvent("ENTER")) {
      showInput()
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

  $(function () {
    // Disable disabled zooming on iPhone (They removed the ability to prevent zooming)
    if (!(/iPad|iPhone|iPod/.test(navigator.userAgent))) return
    $(document.head).append('<style>*{cursor:pointer;-webkit-tap-highlight-color:rgba(0,0,0,0)}</style>')
    $(window).on('gesturestart touchmove', function (evt) {
      if (evt.originalEvent.scale !== 1) {
        evt.originalEvent.preventDefault()
      }
    })
  })

  setInterval(tick, 1);
  setInterval(actOnKeysPressed, 5);
  showChatBox()
  hideChatBox()
  currentPlayer.logIn(function() {
    var playerPos = currentPlayer.html.position(), newLeft = playerPos.left - ($(window).width() / 2) + (littleWorld.blockWidth / 2), newTop = playerPos.top - ($(window).height() / 2);
    setTimeout(function() {
      $("body, html").stop().scrollLeft(newLeft).scrollTop(newTop)
    }, 200)
  })
})
