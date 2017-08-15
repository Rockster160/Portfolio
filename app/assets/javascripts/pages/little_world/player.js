canCameraChange = true
function LittleWorld() {
  this.players = []
  this.blockWidth = $(".block").width()
  this.blockHeight = $(".block").height()
  this.boardWidth = parseInt($(".little-world-wrapper").attr("data-world-width"))
  this.boardHeight = parseInt($(".little-world-wrapper").attr("data-world-height"))
}

LittleWorld.prototype.loginPlayer = function(player_id) {
  var url = $(".little-world-wrapper").attr("data-player-login-url")
  if (Player.findPlayer(player_id) != undefined) { return }
  $.get(url, { uuid: player_id }).success(function(data) {
    var player = new Player($(data))
    littleWorldPlayers.push(player)
    $(".little-world-wrapper").append(player.html)
    player.logIn()
    console.log("Players Logged In: ", littleWorldPlayers.length);
  })
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
  // FIXME: Walking backwards because this rounds instead of floors?
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
  var default_coord = [30, 30]
  this.id = parseInt(player_html.attr("data-id")) || 1234
  this.x = parseInt(player_html.attr("data-location-x")) || default_coord[0]
  this.y = parseInt(player_html.attr("data-location-y")) || default_coord[1]
  this.html = $(player_html)
  this.character = $(player_html).find(".character")
  this.path = []
  this.isMoving = false
  this.lastMoveTimestamp = 0
  this.destination
  // this.walkingTimer
}

Player.tick = function() {
  $(littleWorldPlayers).each(function() {
    this.tick()
  })
}

Player.findPlayer = function(playerId) {
  var player
  playerId = parseInt(playerId)
  $(littleWorldPlayers).each(function() {
    if (this.id == playerId) { return player = this }
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
  coord = coord || this.currentCoord()
  var x = coord[0], y = coord[1]
  this.x = x
  this.y = y

  var blockPosition = littleWorld.getBlockAtCoord([x, y]).position()
  // FIXME walking backwards
  var newPosition = {
    left: blockPosition.left,
    top: blockPosition.top
  };
  this.html.css(newPosition)
}

Player.prototype.setDestination = function(coord) {
  coord[0] = parseInt(coord[0])
  coord[1] = parseInt(coord[1])
  var player = this
  if (player.destination != undefined && player.destination[0] == coord[0] && player.destination[1] == coord[1]) { return }
  var playerCoord = player.currentCoord();
  if (coord == playerCoord) { return }

  var world = littleWorld.walkables();
  var new_path = findPath(world, playerCoord, coord);
  player.path = new_path
  canCameraChange = true

  if (player.path.length > 0) {
    littleWorld.highlightDestination(coord)
    if (player.destination != coord) {
      player.destination = coord
      postDestination()
    }
  }
}

Player.prototype.updateCoord = function(coord) {
  this.x = coord[0]
  this.y = coord[1]
}

Player.prototype.logIn = function() {
  var player = this
  setTimeout(function() {
    player.jumpTo()
    player.html.removeClass("hidden")
  }, 10)
}

Player.prototype.logOut = function() {
  var player = this
  this.html.remove()
  littleWorldPlayers = littleWorldPlayers.filter(function() {
    return player.id != this.id
  })
  console.log("Players Logged In: ", littleWorldPlayers.length);
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
