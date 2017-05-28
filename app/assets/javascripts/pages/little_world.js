$('.ctr-little_worlds').ready(function() {

  var playerPath = [];
  var playerMoving = false;
  // 0 - notMoving, 1 - North/Up/-Y, 2 - East/Right/+X, 3 - South/Down/+Y, 4 - West/Left/-X
  var boardWidth = 51;
  var boardHeight = boardWidth;
  var blockWidth = 20;
  var blockHeight = blockWidth;

  $('.little-world-wrapper').css({width: (boardWidth * blockWidth) + "px", height: (boardHeight * blockHeight) + "px"})
  $('.little-world-wrapper').append($('<div>', {class: 'output'}))
  $('.little-world-wrapper').append($('<div>', {class: 'game'}))
  $('.game').append($('<div>', {class: 'player'}))
  for (i=0;i<boardWidth*boardHeight;i++) {
    $('.game').append($('<div>', {class: 'block walkable', style: 'width: ' + blockWidth +  'px; height: ' + blockHeight +  'px;'}))
  }

  $('.block').on('click tap touch', function(evt) {
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
        break;
      case KEY_EVENT_UP:
      case KEY_EVENT_W:
        movePlayerRelative([0, -1]);
        break;
      case KEY_EVENT_DOWN:
      case KEY_EVENT_S:
        movePlayerRelative([0, 1]);
        break;
      case KEY_EVENT_RIGHT:
      case KEY_EVENT_D:
        movePlayerRelative([1, 0]);
        break;
    }
  })

  setPlayerDestination = function(coord) {
    playerPath = [];
    var timer = setInterval(function() {
      if (playerMoving) { return }
      clearInterval(timer);
      var currentCoord = playerCoord();
      var world = getArrayOfWalkablesForWorld();
      playerPath = findPath(world, currentCoord, coord);
    }, 1);
  }
  movePlayerRelative = function(relativeCoord) {
    var timer = setInterval(function() {
      if (playerMoving) { return }
      clearInterval(timer);
      var currentCoord = playerCoord();
      setPlayerDestination([currentCoord[0] + relativeCoord[0], currentCoord[1] + relativeCoord[1]])
    }, 1);
  }

  playerCoord = function() {
    return convertPositionToCoord($('.player').position());
  }

  walkPlayerTo = function(coord) {
    var oldPosition = $('.player').position();
    var newPosition = {
      left: coord[0] * blockWidth,
      top: coord[1] * blockHeight
    };

    if (oldPosition.left == newPosition.left && oldPosition.top == newPosition.top) { return }

    playerMoving = true;
    $('.player').animate(newPosition, {
      duration: 100,
      complete: function() {
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
    var worldPieces = []
    while(flatWorld.length > 0) { worldPieces.push(flatWorld.splice(0, boardWidth)) };
    return worldPieces;
  }

  tick = function() {
    if (playerMoving || playerPath.length == 0) { return }
    var nextCoord = playerPath.shift(), lastCoord = playerPath[playerPath.length - 1];

    if (coordIsWalkable(nextCoord)) {
      walkPlayerTo(nextCoord);
    } else {
      setPlayerDestination(lastCoord);
    }
  }

  setInterval(tick, 5);
  walkPlayerTo([5, 5]);
})
