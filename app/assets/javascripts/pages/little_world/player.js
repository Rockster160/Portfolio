canCameraChange = true

class LittleWorld {
  constructor() {
    this.players = []
    this.blockWidth = $(".block").width()
    this.blockHeight = $(".block").height()
    this.boardWidth = parseInt($(".little-world-wrapper").attr("data-world-width"))
    this.boardHeight = parseInt($(".little-world-wrapper").attr("data-world-height"))
  }

  getBlockAtCoord(coord) {
    return $('.block[data-x="' + coord[0] + '"][data-y="' + coord[1] + '"]')
  }
  getCoordForBlock(block) {
    return [parseInt($(block).attr("data-x")), parseInt($(block).attr("data-y"))]
  }

  blockisWalkable(block) {
    return $(block).hasClass("walkable");
  }
  coordIsWalkable(coord) {
    return this.blockisWalkable(this.getBlockAtCoord(coord));
  }

  getBlockAtPosition(position) {
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

  convertPositionToCoord(position) {
    var block = getBlockAtPosition(position)
    return this.getCoordForBlock(block)
  }

  highlightDestination(coord) {
    $(".highlight-coord").removeClass("highlight-coord")
    this.getBlockAtCoord(coord).addClass("highlight-coord")
  }

  walkables() {
    var worldMap = []
    $(".block[data-x][data-y]").each(function() {
      var coord = littleWorld.getCoordForBlock(this)
      var x = coord[0], y = coord[1]
      worldMap[x] = worldMap[x] || []
      worldMap[x][y] = littleWorld.blockisWalkable(this) ? 0 : 1
    })
    return worldMap
  }
}

littleWorldPlayers = []
class Player {
  constructor(player_html) {
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

  static tick() {
    $(littleWorldPlayers).each(function() {
      this.tick()
    })
  }

  static findPlayerBy(playerId) {
    var player;
    $(littleWorldPlayers).each(function() {
      if (this.id == playerId) { return player }
    })
    return player
  }

  tick() {
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

  currentCoord() {
    return [this.x, this.y]
  }

  clearMovementClasses() {
    this.character.removeClass("spell-up spell-down spell-left spell-right thrust-up thrust-down thrust-left thrust-right walk-up walk-down walk-left walk-right slash-up slash-down slash-left slash-right shoot-up shoot-down shoot-left shoot-right die")
  }

  setLocation() {
    var newPosition = littleWorld.getBlockAtCoord([this.x, this.y]).position()
    this.html.css(newPosition)
  }

  switchDirection(newDirection) {
    if (this.character.hasClass("stand-" + newDirection)) { return }
    this.clearMovementClasses()
    this.character.removeClass("stand-up stand-down stand-left stand-right")
    this.character.addClass("stand-" + newDirection)
  }

  walkDirection(direction) {
    if (this.character.hasClass("walk-" + direction)) { return }
    this.switchDirection(direction)
    void this.character[0].offsetWidth
    this.character.addClass("walk-" + direction)
  }

  jumpTo(coord) {
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

  setDestination(coord) {
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

  updateCoord(coord) {
    this.x = coord[0]
    this.y = coord[1]
  }

  walkTo(coord) {
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
}
