var seed = 3141;
function random() {
  var x = Math.sin(seed++) * 10000;
  return x - Math.floor(x);
}
function randRange(start, end) {
  return Math.round(start + (random() * (end - start)));
}

$('.ctr-little_worlds.act-show').ready(function() {

  var ticksPerMovementFrame = 5
  var lastBlockHoveredCoord = [];
  var screenMessage;
  var canCameraChange = true
  currentPlayer = new Player($(".player"))
  littleWorld = new LittleWorld()
  littleWorldPlayers.push(currentPlayer)

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
    var coord = currentPlayer.destination
    var url = $("[data-save-location-url]").attr("data-save-location-url")
    var params = { avatar: { location_x: coord[0], location_y: coord[1], timestamp: nowStamp() } }
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

  $(document).keyup(function(evt) {
    if (triggerEvent(evt.which, "up")) {
      evt.preventDefault()
      return false
    }
  }).keydown(function(evt) {
    if (triggerEvent(evt.which, "down")) {
      evt.preventDefault()
      return false
    }
  })

  $('.block.walkable').on('click tap touch', function(evt) {
    var newCoord = littleWorld.getCoordForBlock(this)
    currentPlayer.setDestination(newCoord);
  })

  $(".block[data-x][data-y]").mouseover(function() {
    lastBlockHoveredCoord = littleWorld.getCoordForBlock(this)
  })

  setInterval(tick, 1);
  setInterval(actOnKeysPressed, 5);
  currentPlayer.setLocation()
})
