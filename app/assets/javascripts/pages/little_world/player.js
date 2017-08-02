canCameraChange = true
function LittleWorld() {
  this.players = []
  this.blockWidth = $(".block").width()
  this.blockHeight = $(".block").height()
  this.boardWidth = parseInt($(".little-world-wrapper").attr("data-world-width"))
  this.boardHeight = parseInt($(".little-world-wrapper").attr("data-world-height"))
}

LittleWorld.prototype.getBlockAtCoord = function(coord) {
  return $('.block[data-x="' + coord[0] + '"][data-y="' + coord[1] + '"]')
}
LittleWorld.prototype.getCoordForBlock = function(block) {
  return [parseInt($(block).attr("data-x")), parseInt($(block).attr("data-y"))]
}

LittleWorld.prototype.blockisWalkable = function(block) {
  return $(block).hasClass("walkable");
}
LittleWorld.prototype.coordIsWalkable = function(coord) {
  return this.blockisWalkable(this.getBlockAtCoord(coord));
}

LittleWorld.prototype.getBlockAtPosition = function(position) {
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

LittleWorld.prototype.convertPositionToCoord = function(position) {
  var block = getBlockAtPosition(position)
  return this.getCoordForBlock(block)
}

LittleWorld.prototype.highlightDestination = function(coord) {
  $(".highlight-coord").removeClass("highlight-coord")
  this.getBlockAtCoord(coord).addClass("highlight-coord")
}

LittleWorld.prototype.walkables = function() {
  var worldMap = []
  $(".block[data-x][data-y]").each(function() {
    var coord = littleWorld.getCoordForBlock(this)
    var x = coord[0], y = coord[1]
    worldMap[x] = worldMap[x] || []
    worldMap[x][y] = littleWorld.blockisWalkable(this) ? 0 : 1
  })
  return worldMap
}

littleWorldPlayers = []
function Player(player_html) {
  this.id = player_html.attr("data-id")
  this.x = player_html.attr("data-location-x")
  this.y = player_html.attr("data-location-y")
  this.html = $(player_html)
  this.character = $(player_html).find(".character")
  this.path = []
  this.isMoving = false
  // this.destination
  // this.walkingTimer
}

Player.tick = function() {
  $(littleWorldPlayers).each(function() {
    this.tick()
  })
}

Player.findPlayerBy = function(playerId) {
  var player;
  $(littleWorldPlayers).each(function() {
    if (this.id == playerId) { return player }
  })
  return player
}

Player.prototype.tick = function() {
  if (this.isMoving || this.path.length == 0) { return }
  var nextCoord
  do {
    nextCoord = this.path.shift()
  } while(this.currentCoord == nextCoord)

  if (littleWorld.coordIsWalkable(nextCoord)) {
    this.walkTo(nextCoord);
  } else {
    console.log("Path is blocked for player " + this.id + ". Retrying...");
    var lastCoord = playerPath[playerPath.length - 1];
    this.setDestination(lastCoord);
  }
}
Player.prototype.currentCoord = function() {
  return [this.x, this.y]
}

Player.prototype.clearMovementClasses = function() {
  this.character.removeClass("spell-up spell-down spell-left spell-right thrust-up thrust-down thrust-left thrust-right walk-up walk-down walk-left walk-right slash-up slash-down slash-left slash-right shoot-up shoot-down shoot-left shoot-right die")
}

Player.prototype.setLocation = function() {
  var newPosition = littleWorld.getBlockAtCoord([this.x, this.y]).position()
  this.html.css(newPosition)
}

Player.prototype.switchDirection = function(newDirection) {
  if (this.character.hasClass("stand-" + newDirection)) { return }
  this.clearMovementClasses()
  this.character.removeClass("stand-up stand-down stand-left stand-right")
  this.character.addClass("stand-" + newDirection)
}

Player.prototype.walkDirection = function(direction) {
  if (this.character.hasClass("walk-" + direction)) { return }
  this.switchDirection(direction)
  void this.character[0].offsetWidth
  this.character.addClass("walk-" + direction)
}

Player.prototype.jumpTo = function(coord) {
  var x = coord[0], y = coord[1]
  this.x = x
  this.y = y
  var blockPosition = littleWorld.getBlockAtCoord([x, y]).position()
  var newPosition = {
    left: blockPosition.left,
    top: blockPosition.top
  };
  this.html.css(newPosition)
}

Player.prototype.setDestination = function(coord) {
  var playerCoord = this.currentCoord();
  if (coord == playerCoord) { return }

  var world = littleWorld.walkables();
  var new_path = findPath(world, playerCoord, coord);
  this.path = new_path
  canCameraChange = true

  if (this.path.length > 0) {
    littleWorld.highlightDestination(coord)
    if (this.destination != coord) {
      this.destination = coord
      postDestination()
    }
  }
}

Player.prototype.updateCoord = function(coord) {
  this.x = coord[0]
  this.y = coord[1]
}

Player.prototype.walkTo = function(coord) {
  var player = this
  var oldPosition = player.html.position()
  var blockPosition = littleWorld.getBlockAtCoord(coord).position()
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
    player.walkDirection("left")
  } else if (walkingRight) {
    player.walkDirection("right")
  } else if (walkingUp) {
    player.walkDirection("up")
  } else if (walkingDown) {
    player.walkDirection("down")
  }

  player.updateCoord(coord)
  player.isMoving = true;
  player.html.animate(newPosition, {
    duration: 400, // Keep in sync with CSS: $walk-animation-duration
    easing: "linear",
    complete: function() {
      if (player.path.length == 0) {
        $(".highlight-coord").removeClass("highlight-coord")
        player.clearMovementClasses()
      }
      player.isMoving = false;
    }
  });
}
