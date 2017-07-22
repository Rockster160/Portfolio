var seed = 3141;
function random() {
  var x = Math.sin(seed++) * 10000;
  return x - Math.floor(x);
}
function randRange(start, end) {
  return Math.round(start + (random() * (end - start)));
}

$('.ctr-little_worlds.act-show').ready(function() {

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
  $(window).keydown(function(evt) {
    switch (evt.which) {
      case KEY_EVENT_LEFT:
      case KEY_EVENT_A:
        movePlayerRelative([-1, 0]);
        evt.preventDefault()
        break;
      case KEY_EVENT_UP:
      case KEY_EVENT_W:
        movePlayerRelative([0, -1]);
        evt.preventDefault()
        break;
      case KEY_EVENT_DOWN:
      case KEY_EVENT_S:
        movePlayerRelative([0, 1]);
        evt.preventDefault()
        break;
      case KEY_EVENT_RIGHT:
      case KEY_EVENT_D:
        movePlayerRelative([1, 0]);
        evt.preventDefault()
        break;
    }
  })

  setPlayerDestination = function(coord) {
    playerPath = [];
    var timer = setInterval(function() {
      clearInterval(timer);
      var currentCoord = currentPlayerCoord;
      var world = getArrayOfWalkablesForWorld();
      playerPath = findPath(world, currentCoord, coord);
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
    clearMovementClasses()
    $('.character').removeClass("stand-up stand-down stand-left stand-right")
    $('.character').addClass("stand-" + newDirection)
  }

  var move = function(direction) {
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
        clearMovementClasses()
        if (playerPath.length == 0) { $(".highlight-coord").removeClass("highlight-coord") }
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

  jumpToPlayer = function() {
    var maxScrollSpeed = 20 // px per tick
    var playerPos = $('.player').position()
    var startLeft = $(window).scrollLeft(), newLeft = playerPos.left - ($(window).width() / 2)
    var startTop = $(window).scrollTop(), newTop = playerPos.top - ($(window).height() / 2)
    $(window).scrollLeft(startLeft + ((newLeft - startLeft) % maxScrollSpeed))
    $(window).scrollTop(startTop + ((newTop - startTop) % maxScrollSpeed))
  }

  tick = function() {
    if (playerMoving) {
      jumpToPlayer()
    }
    if (playerMoving || playerPath.length == 0) { return }
    var nextCoord = playerPath.shift(), lastCoord = playerPath[playerPath.length - 1];

    if (coordIsWalkable(nextCoord)) {
      walkPlayerTo(nextCoord);
    } else {
      console.log("tick");
      setPlayerDestination(lastCoord);
    }
  }

  setInterval(tick, 1);
  jumpPlayerTo([5, 5]);
})
