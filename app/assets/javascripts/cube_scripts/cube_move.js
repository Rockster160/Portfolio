const keyCode("LEFT") = 37,
      keyCode("UP") = 38,
      keyCode("DOWN") = 40,
      keyCode("RIGHT") = 39,
      KET_EVENT_SHIFT = 16;

$(document).ready(function() {
  var easeMotionTimer;

  getRotation = function() {
    var current_rotation = cube.rotation
    return {x: current_rotation.y * 180 / Math.PI, y: current_rotation.x * 180 / Math.PI, z: current_rotation.z * 180 / Math.PI};
  }
  normDeg = function(deg) {
    return ((deg % 360) + 360) % 360;
  }
  diffBetween = function(startDeg, endDeg) {
    var modStart, modEnd, rawDiff, cappedDiff, degDiff, diffSign;
    modStart = startDeg % 360;
    modEnd = endDeg % 360;
    rawDiff = modStart - modEnd;
    cappedDiff = Math.abs(rawDiff) % 360;
    degDiff = cappedDiff > 180 ? 360 - cappedDiff : cappedDiff;
    clockDiff = (startDeg + degDiff) % 360;
    diffSign = (clockDiff == endDeg % 360) ? 1 : -1;

    return degDiff * diffSign;
  }
  easeRotate = function(goalRotation, maxEaseDuration) {
    clearInterval(easeMotionTimer);
    var msPerFrame = 10,
        currentFrame = 0,
        minDegPerMs = 180 / maxEaseDuration,
        minDegPerFrame = minDegPerMs * msPerFrame,
        currentRotation = getRotation(),
        xStart = normDeg(currentRotation.x),
        yStart = normDeg(currentRotation.y),
        zStart = normDeg(currentRotation.z),
        xEnd = normDeg(goalRotation.x),
        yEnd = normDeg(goalRotation.y),
        zEnd = normDeg(goalRotation.z),
        xDiff = diffBetween(xStart, xEnd),
        yDiff = diffBetween(yStart, yEnd),
        zDiff = diffBetween(zStart, zEnd),
        maxDiff = [ Math.abs(xDiff), Math.abs(yDiff), Math.abs(zDiff) ].sort(function(a, b) { return b - a; })[0],
        frames = Math.round(maxDiff / minDegPerFrame),
        xStep = xDiff / frames,
        yStep = yDiff / frames,
        zStep = zDiff / frames;
    if (xDiff == 0 && yDiff == 0 && zDiff == 0) { return }

    easeMotion = function() {
      if (currentFrame < frames) {
        currentFrame += 1;
        var nextX = xStart + (xStep * currentFrame);
        var nextY = yStart + (yStep * currentFrame);
        var nextZ = zStart + (zStep * currentFrame);
        immediateRotate(nextX, nextY, nextZ);
      } else {
        immediateRotate(xEnd, yEnd, zEnd);
        clearInterval(easeMotionTimer);
      }
    }
    clearInterval(easeMotionTimer);
    easeMotionTimer = setInterval(function() {
      easeMotion()
    }, msPerFrame);
  }
  relativeRotate = function(x, y, z) {
    var currentRotation = getRotation();
    immediateRotate(x + currentRotation.x, y + currentRotation.y, z + currentRotation.z);
  }
  easeRelativeRotate = function(x, y, z) {
    var currentRotation = getRotation();
    easeRotate({x: x + currentRotation.x, y: y + currentRotation.y, z: z + currentRotation.z}, 500);
  }
  rotateLeft = function() { relativeRotate(-2, 0, 0) }
  rotateUp = function() { relativeRotate(0, -2, 0) }
  rotateDown = function() { relativeRotate(0, 2, 0) }
  rotateRight = function() { relativeRotate(2, 0, 0) }
  // 1 - ( --k * k * k * k )
  immediateRotate = function(x, y, z) { cube.rotation.set(y * Math.PI / 180, x * Math.PI / 180, z * Math.PI / 180) }
  immediateRotate(335, 25, 0);

  $(document).on("mouseenter", ".sticker", function() {
    $(this).addClass("hover-highlight");
  }).on("mouseleave", ".sticker", function() {
    $(this).removeClass("hover-highlight");
  })

  $(document).keydown(function(evt) {
    var key = String.fromCharCode( evt.which )
    // console.log("Pressed: " + key);
    if ($('.hover-highlight').length > 0) {
      // sticker = $('.hover-highlight');
      // dom_cubelet = sticker.parents('.cubelet');
      // cubelet = cube.cubelets[getCubeletIdFromDomCubelet(dom_cubelet)];
      // dom_cubelet.trigger("mousedown", { clientX: dom_cubelet.offset().left, clientY: dom_cubelet.offset().top })
    }

    switch (key) {
      case "1": // White
      easeRotate({x: 335, y: 25, z: 0}, 500);
      break;
      case "2": // Orange
      easeRotate({x: 0, y: 295, z: 155}, 500);
      break;
      case "3": // Blue
      easeRotate({x: 245, y: 25, z: 0}, 500);
      break;
      case "4": // Red
      easeRotate({x: 0, y: 295, z: 335}, 500);
      break;
      case "5": // Green
      easeRotate({x: 65, y: 25, z: 0}, 500);
      break;
      case "6": // Yellow
      easeRotate({x: 155, y: 25, z: 0}, 500);
      break;
    }
  }).keyup(function(evt) {
    if (evt.shiftKey) {
      switch (evt.which) {
        case keyCode("LEFT"):
          easeRelativeRotate(-90, 0, 0);
          break;
        case keyCode("UP"):
          easeRelativeRotate(0, -90, 0);
          break;
        case keyCode("DOWN"):
          easeRelativeRotate(0, 90, 0);
          break;
        case keyCode("RIGHT"):
          easeRelativeRotate(90, 0, 0);
          break;
      }
    }
  })
  $(window, document).blur(function() { keysPressed = []; })

  tick = setInterval(function() {
    if ($('.hover-highlight').length == 0) {
      var shiftPressed = keysPressed.includes(KET_EVENT_SHIFT);
      if (shiftPressed) { return }
      if (keysPressed.includes(keyCode("LEFT"))) { rotateLeft() };
      if (keysPressed.includes(keyCode("UP"))) { rotateUp() };
      if (keysPressed.includes(keyCode("DOWN"))) { rotateDown() };
      if (keysPressed.includes(keyCode("RIGHT"))) { rotateRight() };
    }
  }, 10)
})

// getCubeletIdFromDomCubelet = function(dom_cubelet) {
//   var cubelet_id_class = dom_cubelet.attr("class").match(/cubeletId-\d+/)[0]
//   return cubelet_id_class.match(/\d+/);
// }
//
// performMove = function(moveString) {
//   var direction = moveString[1] == "'" ? "counter-clockwise" : "clockwise";
//   var moveCount = moveString[1] == "2" ? 2 : 1;
//   var face = moveString[0];
// }
