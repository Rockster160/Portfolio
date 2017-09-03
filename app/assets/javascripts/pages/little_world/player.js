canCameraChange = true
function LittleWorld() {
  this.players = []
  this.blockWidth = $(".block").width()
  this.blockHeight = $(".block").height()
  this.boardWidth = parseInt($(".little-world-wrapper").attr("data-world-width"))
  this.boardHeight = parseInt($(".little-world-wrapper").attr("data-world-height"))
}

LittleWorld.prototype.connected = function() {
  this.loadOnlinePlayers()
  $(".connection-error-status").animate({"top": -50 - $(".connection-error-status").height()})
}
LittleWorld.prototype.disconnected = function() {
  $(".connection-error-status").animate({"top": "30px"})
}

LittleWorld.prototype.loadOnlinePlayers = function() {
  App.little_world.ping()
}

LittleWorld.prototype.loginPlayer = function(data, callback) {
  var url = $(".little-world-wrapper").attr("data-player-login-url")
  var player_id = data.uuid
  if (Player.findPlayer(player_id) != undefined) { return }
  $.get(url, { uuid: player_id }).success(function(data) {
    var player = new Player($(data))
    littleWorldPlayers.push(player)
    player.logIn()
    console.log("Players Logged In: ", littleWorldPlayers.length);
    player.reactToData(data)
    if (callback != undefined) { callback() }
  })
}

LittleWorld.prototype.addMessageText = function(message) {
  var message_html = $("<div>", {class: "message", timestamp: (new Date()).getTime()})
  this.addMessage(message_html.append(message))
}

LittleWorld.prototype.addMessage = function(message_html) {
  showChatBox()
  $(".messages-container").append(message_html)
  if (!$(".chat-input").is(":focus")) {
    $(".messages-container").scrollTop($(".messages-container")[0].scrollHeight)
  }
  hideChatBox()
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
  var default_coord = [30, 30]
  this.id = parseInt(player_html.attr("data-id")) || 1234
  this.x = parseInt(player_html.attr("data-location-x")) || default_coord[0]
  this.y = parseInt(player_html.attr("data-location-y")) || default_coord[1]
  this.html = $(player_html)
  this.character = $(player_html).find(".character")
  this.username = player_html.find(".username").text()
  this.path = []
  this.isMoving = false
  this.lastMoveTimestamp = parseInt(player_html.attr("data-timestamp")) || (new Date()).getTime()
  this.destination
  this.messageTimer
  // this.walkingTimer
}

Player.tick = function() {
  $(Player.sleepingPlayers()).each(function() {
    this.goToSleep()
  })
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

Player.sleepingPlayers = function() {
  var sleeping = []
  var sleepingTime = nowStamp() - minutes(10)
  $(littleWorldPlayers).each(function() {
    var player = this
    if (player.lastMoveTimestamp < sleepingTime) { sleeping.push(player) }
  })
  return sleeping
}

Player.prototype.tick = function() {
  if (this.isMoving) { this.updateZIndex() }
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

Player.prototype.goToSleep = function() {
  var player = this
  if (player.html.hasClass("sleeping")) { return }
  player.addMessage("Zzz")
  player.html.addClass("sleeping")
}

Player.prototype.wakeUp = function() {
  var player = this
  if (!player.html.hasClass("sleeping")) { return }
  var message_container = $(player.html).find(".message-container")
  player.html.removeClass("sleeping")

  message_container.fadeOut(1000, function() {
    message_container.addClass("hidden")
    message_container.css({
      "opacity": 1,
      "display": "block",
    })
  })
}

Player.prototype.updateZIndex = function() {
  this.html.css("z-index", this.y + 10)
}

Player.prototype.currentCoord = function() {
  return [this.x, this.y]
}

Player.prototype.clearMovementClasses = function() {
  this.character.removeClass("spell-up spell-down spell-left spell-right thrust-up thrust-down thrust-left thrust-right walk-up walk-down walk-left walk-right slash-up slash-down slash-left slash-right shoot-up shoot-down shoot-left shoot-right die")
}

Player.prototype.addMessage = function(message) {
  var player = this
  var message_container = $(player.html).find(".message-container")
  message_container.addClass("hidden")
  message_container.css({
    "opacity": 1,
    "display": "block",
  })
  var message_html = message_container.find(".message")
  message_html.html(message)
  if (message.length <= 5) {
    message_html.css("text-align", "center")
  } else {
    message_html.css("text-align", "left")
  }
  message_container.removeClass("hidden")
  message_container.stop()
}

Player.prototype.say = function(message_html) {
  var player = this
  var message_text = $(message_html).find(".text")
  var message_container = $(player.html).find(".message-container")

  player.wakeUp()
  littleWorld.addMessage(message_html)
  player.addMessage(message_text)

  clearTimeout(player.messageTimer)
  player.messageTimer = setTimeout(function() {
    message_container.fadeOut(1000, function() {
      message_container.addClass("hidden")
      message_container.css({
        "opacity": 1,
        "display": "block",
      })
    })
  }, 3000 + (message_text.length * 20))
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
  var newPosition = {
    left: blockPosition.left,
    top: blockPosition.top
  };
  this.html.css(newPosition)
  this.updateZIndex()
}

Player.prototype.setDestination = function(coord) {
  if (coord[0] == undefined || coord[1] == undefined) { return }
  coord[0] = parseInt(coord[0])
  coord[1] = parseInt(coord[1])

  var player = this
  player.wakeUp()
  if (player.destination != undefined && player.destination[0] == coord[0] && player.destination[1] == coord[1]) { return }
  var playerCoord = player.currentCoord();
  if (coord == playerCoord) { return }

  var world = littleWorld.walkables();
  var new_path = findPath(world, playerCoord, coord);
  player.path = new_path
  canCameraChange = true

  if (player.path.length > 0) {
    if (player.destination != coord) {
      player.destination = coord
    }
    if (player.id == currentPlayer.id) {
      littleWorld.highlightDestination(coord)
      postDestination()
    }
  }
}

Player.prototype.updateCoord = function(coord) {
  this.x = coord[0]
  this.y = coord[1]
}

Player.prototype.reactToData = function(data) {
  var player = this

  if ($(".player[data-id=" + player.id + "]").length == 0) { player.logIn() }
  if (data.message && data.message.length > 0) { player.say(data.message) }
  if (data.x != undefined && data.y != undefined && player.lastMoveTimestamp < parseInt(data.timestamp)) {
    player.setDestination([data.x, data.y])
  }
  if (data.timestamp) { player.lastMoveTimestamp = parseInt(data.timestamp) }
  if (data.log_out) { player.logOut() }
}

Player.prototype.logIn = function(callback) {
  var player = this
  var shouldLoadPlayer = $(".player[data-id=" + player.id + "]").length == 0
  if (shouldLoadPlayer) { $(".little-world-wrapper").append(player.html) }
  setTimeout(function() {
    player.jumpTo()
    player.html.removeClass("hidden")
    if (player.id != currentPlayer.id && shouldLoadPlayer && player.lastMoveTimestamp > nowStamp() - seconds(5)) {
      littleWorld.addMessageText(player.username + " has logged in.")
    }
    if (callback != undefined) { callback() }
  }, 10)
}

Player.prototype.logOut = function() {
  var player = this
  this.html.remove()
  littleWorldPlayers = littleWorldPlayers.filter(function() {
    return player.id != this.id
  })
  littleWorld.addMessageText(player.username + " has logged out.")
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
