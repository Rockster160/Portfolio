var seed = 3141;
function random() {
  var x = Math.sin(seed++) * 10000;
  return x - Math.floor(x);
}
function randRange(start, end) {
  return Math.round(start + (random() * (end - start)));
}

$('.ctr-little_worlds.act-show').ready(function() {

  preventKeyEvents = true

  var ticksPerMovementFrame = 100
  var playerPath = [];
  var currentPlayerCoord;
  var playerMoving = false;
  // 0 - notMoving, 1 - North/Up/-Y, 2 - East/Right/+X, 3 - South/Down/+Y, 4 - West/Left/-X
  var blockWidth = $(".block").width();
  var blockHeight = $(".block").height();
  var boardWidth = $(".little-world-wrapper").width() / blockWidth;
  var boardHeight = $(".little-world-wrapper").height() / blockHeight;

  $('.block.walkable').on('click tap touch', function(evt) {
    var blockIdx = $('.block').index($(this));
    var blockX = blockIdx % boardWidth;
    var blockY = Math.floor(blockIdx / boardHeight);
    setPlayerDestination([blockX, blockY]);
  })

  actOnKeysPressed = function() {
    if (isKeyPressed(KEY_EVENT_SPACE)) {
      scrollToPlayer()
    }
    if (isKeyPressed(KEY_EVENT_LEFT) || isKeyPressed(KEY_EVENT_A)) {
      movePlayerRelative([-1, 0])
    }
    if (isKeyPressed(KEY_EVENT_UP) || isKeyPressed(KEY_EVENT_W)) {
      movePlayerRelative([0, -1])
    }
    if (isKeyPressed(KEY_EVENT_DOWN) || isKeyPressed(KEY_EVENT_S)) {
      movePlayerRelative([0, 1])
    }
    if (isKeyPressed(KEY_EVENT_RIGHT) || isKeyPressed(KEY_EVENT_D)) {
      movePlayerRelative([1, 0])
    }
  }

  setPlayerDestination = function(coord) {
    var timer = setInterval(function() {
      clearInterval(timer);
      var currentCoord = currentPlayerCoord;
      var world = getArrayOfWalkablesForWorld();
      var new_path = findPath(world, currentCoord, coord);
      playerPath = new_path
      if (playerPath.length > 0) {
        highlightDestination(coord)
      }
    }, 1);
  }
  movePlayerRelative = function(relativeCoord) {
    var timer = setInterval(function() {
      clearInterval(timer);
      var currentCoord = currentPlayerCoord;
      var leftOnLeftBorder = relativeCoord[0] < 0 && currentCoord[0] % boardWidth == 0,
          rightOnRightBorder = relativeCoord[0] > 0 && currentCoord[0] % boardWidth == boardWidth - 1,
          topOnTopBorder = relativeCoord[1] < 0 && currentCoord[1] % boardHeight == 0,
          bottomOnBottomBorder = relativeCoord[1] > 0 && currentCoord[1] % boardHeight == boardHeight - 1
      if (leftOnLeftBorder || rightOnRightBorder || topOnTopBorder || bottomOnBottomBorder) { return }
      setPlayerDestination([currentCoord[0] + relativeCoord[0], currentCoord[1] + relativeCoord[1]])
    }, 1);
  }

  highlightDestination = function(coord) {
    $(".highlight-coord").removeClass("highlight-coord")
    $(getBlockAtCoord(coord)).addClass("highlight-coord")
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
    $('.player').css({left: coord[0] * blockWidth, top: coord[1] * blockHeight})
  }

  walkPlayerTo = function(coord) {
    var oldPosition = $('.player').position();
    var newPosition = {
      left: coord[0] * blockWidth,
      top: coord[1] * blockHeight
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
    var xCoord = coord[0], yCoord = coord[1], index = xCoord + (yCoord * boardWidth);
    if (xCoord < 0 || xCoord >= boardWidth || yCoord < 0 || yCoord >= boardHeight) { return }
    return $('.block')[index];
  }

  blockisWalkable = function(block) {
    return $(block).hasClass("walkable");
  }
  coordIsWalkable = function(coord) {
    return blockisWalkable(getBlockAtCoord(coord));
  }

  convertPositionToCoord = function(position) {
    return [Math.floor(position.left / blockWidth), Math.floor(position.top / blockHeight)];
  }

  getArrayOfWalkablesForWorld = function() {
    var flatWorld = $('.block').map(function() { return blockisWalkable(this) ? 0 : 1; });
    var worldCols = []
    while(flatWorld.length > 0) { worldCols.push(flatWorld.splice(0, boardWidth)) };
    worldRows = worldCols[0].map(function(col, i) {
      return worldCols.map(function(row) {
        return row[i]
      })
    });
    return worldRows;
  }

  scrollToPlayer = function() {
    var maxScrollSpeed = ticksPerMovementFrame // px per movement frame == px per 100 ticks
    var playerPos = $('.player').position()
    var startLeft = $(window).scrollLeft(), newLeft = playerPos.left - ($(window).width() / 2) + (blockWidth / 2)
    var startTop = $(window).scrollTop(), newTop = playerPos.top - ($(window).height() / 2)

    scrollLeftDiff = newLeft - startLeft
    if (scrollLeftDiff > maxScrollSpeed) { scrollLeftDiff = maxScrollSpeed }
    if (scrollLeftDiff < -maxScrollSpeed) { scrollLeftDiff = -maxScrollSpeed }

    scrollTopDiff = newTop - startTop
    if (scrollTopDiff > maxScrollSpeed) { scrollTopDiff = maxScrollSpeed }
    if (scrollTopDiff < -maxScrollSpeed) { scrollTopDiff = -maxScrollSpeed }

    $("body, html").animate({
      scrollLeft: startLeft + scrollLeftDiff,
      scrollTop: startTop + scrollTopDiff
    }, 100)
  }

  tick = function() {
    if (playerMoving || playerPath.length == 0) { return }
    var nextCoord = playerPath.shift(), lastCoord = playerPath[playerPath.length - 1];

    if (coordIsWalkable(nextCoord)) {
      walkPlayerTo(nextCoord);
    } else {
      console.log("Path is blocked. Retrying...");
      setPlayerDestination(lastCoord);
    }
  }

  setInterval(tick, 1);
  setInterval(actOnKeysPressed, ticksPerMovementFrame);
  jumpPlayerTo([30, 30]);
})
