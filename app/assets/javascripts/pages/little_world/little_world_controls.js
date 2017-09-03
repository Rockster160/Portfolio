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

  isUsingMobileDevice = function() {
    var user_agent = (navigator.userAgent||navigator.vendor||window.opera);
    var mobile_user_agent_regexp = /(android|bb\d+|meego).+mobile|avantgo|bada\/|blackberry|blazer|compal|elaine|fennec|hiptop|iemobile|ip(hone|od)|iris|kindle|lge |maemo|midp|mmp|mobile.+firefox|netfront|opera m(ob|in)i|palm( os)?|phone|p(ixi|re)\/|plucker|pocket|psp|series(4|6)0|symbian|treo|up\.(browser|link)|vodafone|wap|windows ce|xda|xiino/i
    var mobile_vendor_regexp = /1207|6310|6590|3gso|4thp|50[1-6]i|770s|802s|a wa|abac|ac(er|oo|s\-)|ai(ko|rn)|al(av|ca|co)|amoi|an(ex|ny|yw)|aptu|ar(ch|go)|as(te|us)|attw|au(di|\-m|r |s )|avan|be(ck|ll|nq)|bi(lb|rd)|bl(ac|az)|br(e|v)w|bumb|bw\-(n|u)|c55\/|capi|ccwa|cdm\-|cell|chtm|cldc|cmd\-|co(mp|nd)|craw|da(it|ll|ng)|dbte|dc\-s|devi|dica|dmob|do(c|p)o|ds(12|\-d)|el(49|ai)|em(l2|ul)|er(ic|k0)|esl8|ez([4-7]0|os|wa|ze)|fetc|fly(\-|_)|g1 u|g560|gene|gf\-5|g\-mo|go(\.w|od)|gr(ad|un)|haie|hcit|hd\-(m|p|t)|hei\-|hi(pt|ta)|hp( i|ip)|hs\-c|ht(c(\-| |_|a|g|p|s|t)|tp)|hu(aw|tc)|i\-(20|go|ma)|i230|iac( |\-|\/)|ibro|idea|ig01|ikom|im1k|inno|ipaq|iris|ja(t|v)a|jbro|jemu|jigs|kddi|keji|kgt( |\/)|klon|kpt |kwc\-|kyo(c|k)|le(no|xi)|lg( g|\/(k|l|u)|50|54|\-[a-w])|libw|lynx|m1\-w|m3ga|m50\/|ma(te|ui|xo)|mc(01|21|ca)|m\-cr|me(rc|ri)|mi(o8|oa|ts)|mmef|mo(01|02|bi|de|do|t(\-| |o|v)|zz)|mt(50|p1|v )|mwbp|mywa|n10[0-2]|n20[2-3]|n30(0|2)|n50(0|2|5)|n7(0(0|1)|10)|ne((c|m)\-|on|tf|wf|wg|wt)|nok(6|i)|nzph|o2im|op(ti|wv)|oran|owg1|p800|pan(a|d|t)|pdxg|pg(13|\-([1-8]|c))|phil|pire|pl(ay|uc)|pn\-2|po(ck|rt|se)|prox|psio|pt\-g|qa\-a|qc(07|12|21|32|60|\-[2-7]|i\-)|qtek|r380|r600|raks|rim9|ro(ve|zo)|s55\/|sa(ge|ma|mm|ms|ny|va)|sc(01|h\-|oo|p\-)|sdk\/|se(c(\-|0|1)|47|mc|nd|ri)|sgh\-|shar|sie(\-|m)|sk\-0|sl(45|id)|sm(al|ar|b3|it|t5)|so(ft|ny)|sp(01|h\-|v\-|v )|sy(01|mb)|t2(18|50)|t6(00|10|18)|ta(gt|lk)|tcl\-|tdg\-|tel(i|m)|tim\-|t\-mo|to(pl|sh)|ts(70|m\-|m3|m5)|tx\-9|up(\.b|g1|si)|utst|v400|v750|veri|vi(rg|te)|vk(40|5[0-3]|\-v)|vm40|voda|vulc|vx(52|53|60|61|70|80|81|83|85|98)|w3c(\-| )|webc|whit|wi(g |nc|nw)|wmlb|wonu|x700|yas\-|your|zeto|zte\-/i;
    return mobile_user_agent_regexp.test(user_agent) || mobile_vendor_regexp.test(user_agent.substr(0,4));
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
    if (isUsingMobileDevice) { $(".chat-box").css("bottom", "50%") }
  }
  hideInput = function() {
    hideChatBox()
    $(".open-chat-btn").removeClass("hidden")
    $(".chat-input").addClass("hidden")
    if (isUsingMobileDevice) { $(".chat-box").css("bottom", "5px") }
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
          App.little_world.speak($(".chat-input").val())
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

  setInterval(tick, 1);
  setInterval(actOnKeysPressed, 5);
  showChatBox()
  hideChatBox()
  currentPlayer.logIn(false, function() {
    var playerPos = currentPlayer.html.position(), newLeft = playerPos.left - ($(window).width() / 2) + (littleWorld.blockWidth / 2), newTop = playerPos.top - ($(window).height() / 2);
    setTimeout(function() {
      $("body, html").stop().scrollLeft(newLeft).scrollTop(newTop)
    }, 200)
  })
})
