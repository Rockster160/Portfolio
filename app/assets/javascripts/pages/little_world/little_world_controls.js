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
  var playerPath = [];
  var currentPlayerCoord;
  var lastBlockHoveredCoord = [];
  var screenMessage;
  var playerMoving = false;
  var canCameraChange = true;
  var blockWidth = $(".block").width();
  var blockHeight = $(".block").height();
  var boardWidth = parseInt($(".little-world-wrapper").attr("data-world-width"));
  var boardHeight = parseInt($(".little-world-wrapper").attr("data-world-height"));

  screenLog = function() {
    $(".screen-log .player-coord").html(currentPlayerCoord[0] + ", " + currentPlayerCoord[1])
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
    if (isKeyPressed(keyEvent("LEFT")) || isKeyPressed(keyEvent("A"))) {
      movePlayerRelative([-1, 0])
    }
    if (isKeyPressed(keyEvent("UP")) || isKeyPressed(keyEvent("W"))) {
      movePlayerRelative([0, -1])
    }
    if (isKeyPressed(keyEvent("DOWN")) || isKeyPressed(keyEvent("S"))) {
      movePlayerRelative([0, 1])
    }
    if (isKeyPressed(keyEvent("RIGHT")) || isKeyPressed(keyEvent("D"))) {
      movePlayerRelative([1, 0])
    }
    if (isKeyPressed(keyEvent("J")) && lastBlockHoveredCoord.length == 2) {
      playerPath = []
      jumpPlayerTo(lastBlockHoveredCoord)
    }
  }

  setPlayerDestination = function(coord) {
    var timer = setInterval(function() {
      clearInterval(timer);
      var currentCoord = currentPlayerCoord;
      var world = getArrayOfWalkablesForWorld();
      var new_path = findPath(world, currentCoord, coord);
      playerPath = new_path
      canCameraChange = true
      if (playerPath.length > 0) {
        highlightDestination(coord)
      }
    }, 1);
  }
  movePlayerRelative = function(relativeCoord) {
    var timer = setInterval(function() {
      clearInterval(timer);
      var currentCoord = currentPlayerCoord;
      setPlayerDestination([currentCoord[0] + relativeCoord[0], currentCoord[1] + relativeCoord[1]])
    }, 1);
  }

  highlightDestination = function(coord) {
    $(".highlight-coord").removeClass("highlight-coord")
    getBlockAtCoord(coord).addClass("highlight-coord")
  }

  playerCoord = function() {
    return convertPositionToCoord($('.player').position());
  }

  var clearMovementClasses = function() {
    $('.character').removeClass("spell-up spell-down spell-left spell-right thrust-up thrust-down thrust-left thrust-right walk-up walk-down walk-left walk-right slash-up slash-down slash-left slash-right shoot-up shoot-down shoot-left shoot-right die")
  }

  var switchDirection = function(newDirection) {
    if ($('.character').hasClass("stand-" + newDirection)) { return }
    clearMovementClasses()
    $('.character').removeClass("stand-up stand-down stand-left stand-right")
    $('.character').addClass("stand-" + newDirection)
  }

  var move = function(direction) {
    if ($('.character').hasClass("walk-" + direction)) { return }
    switchDirection(direction)
    void $('.character')[0].offsetWidth
    $('.character').addClass("walk-" + direction)
  }

  jumpPlayerTo = function(coord) {
    currentPlayerCoord = coord
    var blockPosition = getBlockAtCoord(coord).position()
    var newPosition = {
      left: blockPosition.left,
      top: blockPosition.top
    };
    $('.player').css(newPosition)
  }

  walkPlayerTo = function(coord) {
    var oldPosition = $('.player').position()
    var blockPosition = getBlockAtCoord(coord).position()
    var newPosition = {
      left: blockPosition.left,
      top: blockPosition.top
    };

    if (oldPosition.left == newPosition.left && oldPosition.top == newPosition.top) { return }
    var walkingLeft = oldPosition.left > newPosition.left
    var walkingRight = oldPosition.left < newPosition.left
    var walkingUp = oldPosition.top > newPosition.top
    var walkingDown = oldPosition.top < newPosition.top

    if (walkingLeft) {
      move("left")
    } else if (walkingRight) {
      move("right")
    } else if (walkingUp) {
      move("up")
    } else if (walkingDown) {
      move("down")
    }

    playerMoving = true;
    currentPlayerCoord = coord
    $('.player').animate(newPosition, {
      duration: 400, // Keep in sync with CSS: $walk-animation-duration
      easing: "linear",
      complete: function() {
        if (playerPath.length == 0) {
          $(".highlight-coord").removeClass("highlight-coord")
          clearMovementClasses()
        }
        playerMoving = false;
      }
    });
  }

  getBlockAtCoord = function(coord) {
    return $('.block[data-x="' + coord[0] + '"][data-y="' + coord[1] + '"]')
  }
  getCoordForBlock = function(block) {
    return [parseInt($(block).attr("data-x")), parseInt($(block).attr("data-y"))]
  }

  blockisWalkable = function(block) {
    return $(block).hasClass("walkable");
  }
  coordIsWalkable = function(coord) {
    return blockisWalkable(getBlockAtCoord(coord));
  }

  getBlockAtPosition = function(position) {
    return $(".block[data-x][data-y]").filter(function() {
      var blockOffset = $(this).offset()
      var pointGreaterThanBlockX = position.left > blockOffset.left
      if (!pointGreaterThanBlockX) { return false }
      var pointInsideBlockBoundingBoxX = position.left < blockOffset.left + blockWidth
      if (!pointInsideBlockBoundingBoxX) { return false }
      var pointGreaterThanBlockY = position.top > blockOffset.top
      if (!pointGreaterThanBlockY) { return false }
      var pointInsideBlockBoundingBoxY = position.top < blockOffset.top + blockHeight
      if (!pointInsideBlockBoundingBoxY) { return false }
      return true
    });
  }

  convertPositionToCoord = function(position) {
    var block = getBlockAtPosition(position)
    return getCoordForBlock(block)
  }

  getArrayOfWalkablesForWorld = function() {
    var worldMap = []
    $(".block[data-x][data-y]").each(function() {
      var coord = getCoordForBlock(this)
      var x = coord[0], y = coord[1]
      worldMap[x] = worldMap[x] || []
      worldMap[x][y] = blockisWalkable(this) ? 0 : 1
    })
    return worldMap
  }

  scrollToPlayer = function() {
    if (!canCameraChange) { return }
    canCameraChange = false

    var maxScrollSpeed = 5 * ticksPerMovementFrame // px per movement frame == px per 100 ticks
    var playerPos = $('.player').position()
    var startLeft = $(window).scrollLeft(), newLeft = playerPos.left - ($(window).width() / 2) + (blockWidth / 2)
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
    if (playerMoving || playerPath.length == 0) { return }
    var nextCoord
    do {
      nextCoord = playerPath.shift()
    } while(currentPlayerCoord == nextCoord)

    // console.log(keysPressed);

    if (coordIsWalkable(nextCoord)) {
      walkPlayerTo(nextCoord);
    } else {
      console.log("Path is blocked. Retrying...");
      var lastCoord = playerPath[playerPath.length - 1];
      setPlayerDestination(lastCoord);
    }
  }

  triggerEvent = function(key, direction) {
    switch(key) {
      case keyEvent("SPACE"):
      case keyEvent("LEFT"):
      case keyEvent("A"):
      case keyEvent("UP"):
      case keyEvent("W"):
      case keyEvent("DOWN"):
      case keyEvent("S"):
      case keyEvent("RIGHT"):
      case keyEvent("D"):
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
    var newCoord = getCoordForBlock(this)
    setPlayerDestination(newCoord);
  })

  $(".block[data-x][data-y]").mouseover(function() {
    lastBlockHoveredCoord = getCoordForBlock(this)
  })

  setInterval(tick, 1);
  setInterval(actOnKeysPressed, 5);
  jumpPlayerTo([30, 30]);
})
