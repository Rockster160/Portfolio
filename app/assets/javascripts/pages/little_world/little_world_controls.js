var seed = 3141;
function random() {
  var x = Math.sin(seed++) * 10000;
  return x - Math.floor(x);
}
function randRange(start, end) {
  return Math.round(start + (random() * (end - start)));
}

chunksLoading = []
$('.ctr-little_worlds.act-show').ready(function() {
  $(".little-world-wrapper").disableSelection()

  var ticksPerMovementFrame = 5,
    lastBlockHoveredCoord = [],
    screenMessage, chatBoxTimer
  currentPlayer = new Player($(".player"))
  littleWorld = new LittleWorld()
  littleWorldPlayers.push(currentPlayer)

  setupLittleWorldChannel()

  screenLog = function() {
    var playerCoord = currentPlayer.currentCoord()
    $(".screen-log .player-coord").html(playerCoord[0] + ", " + playerCoord[1])
    var destination = currentPlayer.destination || playerCoord
    $(".screen-log .destination-coord").html(destination[0] + ", " + destination[1])
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
    var timestamp = nowStamp()
    if (timestamp < currentPlayer.lastMoveTimestamp) { return }
    var coord = currentPlayer.destination
    try { coord[0] } catch(err) { debugger }
    var url = $("[data-save-location-url]").attr("data-save-location-url")
    var params = { avatar: { location_x: coord[0], location_y: coord[1], timestamp: timestamp } }
    currentPlayer.lastMoveTimestamp = timestamp
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
    jumpToPlayer()
    Player.tick()
  }

  jumpToPlayer = function() {
    if (!currentPlayer) { return }
    var playerPos = currentPlayer.html.position(),
      newLeft = playerPos.left - ($(window).width() / 2) + (littleWorld.blockWidth / 2),
      newTop = playerPos.top - ($(window).height() / 2)

    $("body, html").stop().scrollLeft(newLeft).scrollTop(newTop)
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

  isMobile = function() {
    return /Android|webOS|iPhone|iPad|iPod|BlackBerry|IEMobile|Opera Mini/i.test(navigator.userAgent)
  }

  currentScroll = {}
  showInput = function() {
    showChatBox()
    $(".open-chat-btn").addClass("hidden")
    $(".chat-input").removeClass("hidden")
    currentScroll = {
      top: $("body").scrollTop(),
      left: $("body").scrollLeft()
    }
    $(".chat-input").focus()
    $(".chat-input").click()
    $("body").scrollTop(currentScroll.top)
    $("body").scrollLeft(currentScroll.left)
    if (isMobile()) { $(".chat-box").css("bottom", "50%") }
  }
  hideInput = function() {
    hideChatBox()
    $(".open-chat-btn").removeClass("hidden")
    $(".chat-input").addClass("hidden")
    if (isMobile()) { $(".chat-box").css("bottom", "5px") }
  }

  showChatBox = function() {
    $(".messages-container").stop()
    $(".messages-container").css({opacity: 1})
    $(".messages-container").removeClass("hidden")
    clearTimeout(chatBoxTimer)
  }
  hideChatBox = function(delay, duration) {
    delay = delay || 5000
    duration = duration || 1000
    $(".messages-container").stop()
    clearTimeout(chatBoxTimer)
    chatBoxTimer = setTimeout(function() {
      $(".messages-container").animate({
        opacity: 0
      }, {
        duration: duration + 1,
        complete: function() { $(".messages-container").addClass("hidden").css("opacity", 1) }
      })
    }, delay + 1)
  }

  coordInBB = function(coord, bb) {
    if (coord.left < bb.left)   { return false }
    if (coord.left > bb.right)  { return false }
    if (coord.top  < bb.top)    { return false }
    if (coord.top  > bb.bottom) { return false }
    return true
  }

  boundingBoxesIntersect = function(bb1, bb2) {
    if (bb1.bottom < bb2.top)     { return false }
    if (bb1.top    > bb2.bottom)  { return false }
    if (bb1.left   > bb2.right)   { return false }
    if (bb1.right  < bb2.left)    { return false }
    return true
  }

  loadChunks = function() {
    if (currentPlayer.isMoving) { chunkTick() }
  }

  chunkTick = function() {
    if (chunksLoading.length > 0) { return }
    var currentlyLoadedChunkCoords = $(".chunk").get().map(function(chunk) { return [parseInt($(chunk).attr("data-chunk-x")), parseInt($(chunk).attr("data-chunk-y"))] })
    var currentChunkMinX = Math.min.apply(null, currentlyLoadedChunkCoords.map(function(coord) { return coord[0] })),
      currentChunkMinY = Math.min.apply(null, currentlyLoadedChunkCoords.map(function(coord) { return coord[1] }))
    var playerChunkCoord = [Math.floor(currentPlayer.x / 16), Math.floor(currentPlayer.y / 16)]

    var horzChunksOnScreen = Math.ceil($(window).outerWidth() / $(".chunk").outerWidth()) + 1
    if (horzChunksOnScreen % 2 == 0) { horzChunksOnScreen += 1 }
    var vertChunksOnScreen = Math.ceil($(window).outerHeight() / $(".chunk").outerHeight()) + 1
    if (vertChunksOnScreen % 2 == 0) { vertChunksOnScreen += 1 }

    var neededChunkCoords = [playerChunkCoord]
    for(var relativeHorzChunkIdx=0;relativeHorzChunkIdx<=horzChunksOnScreen;relativeHorzChunkIdx++) {
      var horzChunk = Math.round(horzChunksOnScreen / 2) - relativeHorzChunkIdx
      for(var relativeVertChunkIdx=0;relativeVertChunkIdx<=vertChunksOnScreen;relativeVertChunkIdx++) {
        var vertChunk = Math.round(vertChunksOnScreen / 2) - relativeVertChunkIdx
        neededChunkCoords.push([playerChunkCoord[0] + horzChunk, playerChunkCoord[1] + vertChunk])
      }
    }

    var chunkCoordsToRemove = currentlyLoadedChunkCoords.filter(function(chunkCoord) {
      return !includeArray(neededChunkCoords, chunkCoord)
    })
    var chunkCoordsToLoad = neededChunkCoords.filter(function(chunkCoord) {
      return !includeArray(currentlyLoadedChunkCoords, chunkCoord)
    })

    chunkCoordsToLoad.sort(function(a, b) {
      var aDiff = Math.abs(playerChunkCoord[0] - a[0]) + Math.abs(playerChunkCoord[1] - a[1])
      var bDiff = Math.abs(playerChunkCoord[0] - b[0]) + Math.abs(playerChunkCoord[1] - b[1])
      return aDiff - bDiff
    })
    chunkCoordsToLoad.forEach(function(chunkToLoad) {
      if (includeArray(currentlyLoadedChunkCoords, chunkToLoad)) { return }
      if (includeArray(chunksLoading, chunkToLoad)) { return }
      chunksLoading.push(chunkToLoad)
    })
    if (chunksLoading.length == 0) { return }
    $.get($(".little-world-wrapper").attr("data-chunk-url"), {coords: chunksLoading}).success(function(data) {
      console.log("Done:", data);
      data.forEach(function(renderedChunk) {
        currentlyLoadedChunkCoords.push([parseInt($(renderedChunk).attr("data-chunk-x")), parseInt($(renderedChunk).attr("data-chunk-y"))])
        $(".game").append(renderedChunk)
      })
      var newChunkMinX = Math.min.apply(null, currentlyLoadedChunkCoords.map(function(coord) { return coord[0] })),
        newChunkMinY = Math.min.apply(null, currentlyLoadedChunkCoords.map(function(coord) { return coord[1] }))
      var positionFix = {
        top: newChunkMinY > currentChunkMinY ? currentChunkMinY - newChunkMinY : 0,
        left: newChunkMinX > currentChunkMinX ? currentChunkMinX - newChunkMinX : 0,
      }
      updateChunks()
      if (positionFix.top > 0 || positionFix.left > 0) {
        currentPlayer.html.stop().css({
          top: parseInt(currentPlayer.html.css("top")) + ($(".chunk").outerWidth() * positionFix.top),
          left: parseInt(currentPlayer.html.css("left")) + ($(".chunk").outerWidth() * positionFix.left)
        })
        console.log("JUMP!");
        currentPlayer.walkTo([currentPlayer.x, currentPlayer.y])
      }
    }).done(function() {
      chunksLoading = []
    }).error(function(data) {
      console.log("Failed to load", data);
    })

    chunkCoordsToRemove.forEach(function(chunkCoord) {
      $(".chunk[data-chunk-x=" + chunkCoord[0] + "][data-chunk-y=" + chunkCoord[1] + "]").remove()
      if (chunkCoord[0] == playerChunkCoord[0]) {
        if (chunkCoord[1] < playerChunkCoord[1]) {
          console.log("JUMP! -Y");
          currentPlayer.html.stop().css({top: parseInt(currentPlayer.html.css("top")) - $(".chunk").outerWidth()})
          currentPlayer.walkTo([currentPlayer.x, currentPlayer.y])
        }
      } else if (chunkCoord[1] == playerChunkCoord[1]) {
        if (chunkCoord[0] < playerChunkCoord[0]) {
          console.log("JUMP! -X");
          currentPlayer.html.stop().css({left: parseInt(currentPlayer.html.css("left")) - $(".chunk").outerWidth()})
          currentPlayer.walkTo([currentPlayer.x, currentPlayer.y])
        }
      }
    })
    updateChunks()
  }

  updateChunks = function() {
    var minX, minY, maxX, maxY
    $(".chunk").each(function() {
      var chunkX = parseInt($(this).attr("data-chunk-x")), chunkY = parseInt($(this).attr("data-chunk-y"))
      if (minX == undefined) { minX = chunkX }; if (chunkX < minX) { minX = chunkX }
      if (minY == undefined) { minY = chunkY }; if (chunkY < minY) { minY = chunkY }
      if (maxX == undefined) { maxX = chunkX }; if (chunkX > maxX) { maxX = chunkX }
      if (maxY == undefined) { maxY = chunkY }; if (chunkY > maxY) { maxY = chunkY }
    })
    var gameWidth = $(".game").width()
    var gameHeight = $(".game").height()
    var chunkWidth = $(".chunk").width()
    var chunkHeight = $(".chunk").height()
    var renderedWidth = chunkWidth * ((maxX - minX) + 1)
    var renderedHeight = chunkHeight * ((maxY - minY) + 1)
    $(".game").css({"width": renderedWidth, "height": renderedHeight})
    $(".chunk").each(function() {
      var chunkX = parseInt($(this).attr("data-chunk-x")), chunkY = parseInt($(this).attr("data-chunk-y"))
      var chunkXCoord = (chunkX - minX) * chunkWidth
      var chunkYCoord = (chunkY - minY) * chunkWidth

      $(this).css({top: chunkYCoord + "px", left: chunkXCoord + "px"})
    })
  }

  $(".open-chat-btn").on("click tap touch", showInput)
  $(".chat-input").on("blur", hideInput)
  $(document).keyup(function(evt) {
    if ($(".chat-input").is(":focus")) {
      if (evt.which == keyEvent("ENTER")) {
        if ($(".chat-input").val().length > 0) {
          App.little_world.speak($(".chat-input").val())
        }
        $(".chat-input").val("")
        $(".chat-input").blur()
      }
    } else if (evt.which == keyEvent("ENTER")) {
      showInput()
    } else {
      if (triggerEvent(evt.which, "up")) {
        evt.preventDefault()
        return false
      }
    }
  }).keydown(function(evt) {
    if ($(".chat-input").is(":focus")) {
      if ($(".chat-input").val().length >= 256) {
        evt.preventDefault()
        return false
      }
    } else {
      if (triggerEvent(evt.which, "down")) {
        evt.preventDefault()
        return false
      }
    }
  }).on("mousedown tap touch", ".block.walkable", function(evt) {
    var newCoord = littleWorld.getCoordForBlock(this)
    currentPlayer.setDestination(newCoord);
  }).on("mouseover", ".block[data-x][data-y]", function() {
    lastBlockHoveredCoord = littleWorld.getCoordForBlock(this)
  }).on("mousewheel wheel", function(evt) {
    // Disable all user scrolling, as we control scrolling by location of character
    evt.preventDefault()
    return false
  })

  // TODO
  // Control zoom amount- should not be able to zoom more/less than supposed to

  updateChunks()
  currentPlayer.logIn()
  setInterval(tick, 1);
  setInterval(actOnKeysPressed, 5);
  setInterval(loadChunks, 1000);
  setTimeout(chunkTick, 1000)
  showChatBox()
  hideChatBox()
})
