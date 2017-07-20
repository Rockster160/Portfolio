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
  var playerMoving = false;
  // 0 - notMoving, 1 - North/Up/-Y, 2 - East/Right/+X, 3 - South/Down/+Y, 4 - West/Left/-X
  var boardWidth = 32;
  var boardHeight = boardWidth;
  var blockWidth = 32;
  var blockHeight = blockWidth;

  (function() {
    getClassForBlock = function() {
      var blockValue = randRange(0, 14)
      if (blockValue <= 5) {
        return "grass-1 walkable"
      } else if (blockValue <= 9) {
        return "grass-2 walkable"
      } else if (blockValue <= 12) {
        return "grass-3 walkable"
      } else if (blockValue <= 14) {
        return "grass-4 walkable"
      }
    }

    $('.little-world-wrapper').css({width: (boardWidth * blockWidth) + "px", height: (boardHeight * blockHeight) + "px"})
    $('.little-world-wrapper').append($('<div>', {class: 'output'}))
    $('.little-world-wrapper').append($('<div>', {class: 'game'}))
    $('.game').append($('<div>', {class: 'player'}).css({width: blockWidth - 6, height: blockHeight - 6}))
    for (i=0;i<boardWidth*boardHeight;i++) {
      var x = i % boardWidth, y = Math.floor(i / boardHeight)
      var block = $('<div>', {class: "block"}).css({width: blockWidth, height: blockHeight})
      if (x == 0 && y == 0) {
        block.addClass("top-left-grass")
      } else if (x == 0 && y == boardHeight - 1) {
        block.addClass("bottom-left-grass")
      } else if (x == boardWidth - 1 && y == 0) {
        block.addClass("top-right-grass")
      } else if (x == boardWidth - 1 && y == boardHeight - 1) {
        block.addClass("bottom-right-grass")
      } else if (x == 0) {
        block.addClass("left-grass")
      } else if (y == 0) {
        block.addClass("top-grass")
      } else if (x == boardWidth - 1) {
        block.addClass("right-grass")
      } else if (y == boardHeight - 1) {
        block.addClass("bottom-grass")
      } else {
        block.addClass(getClassForBlock())
        if (randRange(0, 15) == 0) {
          block.removeClass("walkable")
          block.append($('<div>', {class: "object stop-walk"}).css({width: blockWidth, height: blockHeight}))
        }
      }
      $('.game').append(block)
    }
    $(".player").append($(".character"))
  })()

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
hasPosted = false
  setPlayerDestination = function(coord) {
    playerPath = [];
    var timer = setInterval(function() {
      if (playerMoving) { return }
      clearInterval(timer);
      var currentCoord = playerCoord();
      var world = getArrayOfWalkablesForWorld();
      if (!hasPosted) {
        for (rowIdx=0;rowIdx<world.length;rowIdx++) {
          console.log(world[rowIdx].join(""));
        }
      }
      hasPosted = true
      playerPath = findPath(world, currentCoord, coord);
      if (playerPath.length > 0) {
        highlightDestination(coord)
      }
    }, 1);
  }
  movePlayerRelative = function(relativeCoord) {
    var timer = setInterval(function() {
      if (playerMoving) { return }
      clearInterval(timer);
      var currentCoord = playerCoord();
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
    $('.player').animate(newPosition, {
      duration: 400,
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

  tick = function() {
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
  walkPlayerTo([5, 5]);
})
