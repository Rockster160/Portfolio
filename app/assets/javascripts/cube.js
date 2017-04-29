$(document).ready(function() {
  if ($('#cube').length > 0) {

    mouseDragging = false;
    cubeRotateY = 0; // Initial Value
    cubeRotateX = 0; // Initial Value
    // cubeRotateY = 150; // Initial Value
    // cubeRotateX = 225; // Initial Value
    previousMouseX = null;
    previousMouseY = null;
    sensitivityX = 10;
    sensitivityY = 10;

    // faceRotations = {
    //   front: { x: 0, y: 0 },
    //   left: { x: 90, y: 0 },
    //   right: { x: 270, y: 0 },
    //   back: { x: 180, y: 0 },
    //   down: { x: 0, y: 90 },
    //   top: { x: 0, y: 270 },
    // }
    fixCubeRotateCaps = function() {
      if (cubeRotateX > 360) { cubeRotateX -= 360; }
      if (cubeRotateY > 360) { cubeRotateY -= 360; }
      if (cubeRotateX < 0) { cubeRotateX += 360; }
      if (cubeRotateY < 0) { cubeRotateY += 360; }
    }
    setCubeRotation = function(x, y) {
      cubeRotateX = x || cubeRotateX;
      cubeRotateY = y || cubeRotateY;
      fixCubeRotateCaps();
      // $('#cube').css({"transform": "rotateX(" + cubeRotateY + "deg) rotateY(" + cubeRotateX + "deg)"});
    }
    var traqballConfig = {
      stage: "cube",
      // axis: [0.5, 0.5, 0.5],
      angle: 0.95,
      // perspective: 800,
      // perspectiveOrigin: "0 0"
    }
    var mytraqball = new Traqball(traqballConfig)
    setCubeRotation();
    relativeRotate = function(x, y) {
      cubeRotateX += x;
      cubeRotateY += y;
      setCubeRotation();
    }

    cetCurrentFace = function() {

    }

    // $(document).on("mousedown", function(evt) {
    //   evt.preventDefault();
    //   mouseDragging = true;
    //   previousMouseX = evt.clientX;
    //   previousMouseY = evt.clientY;
    // }).on("mouseup", function(evt) {
    //   evt.preventDefault();
    //   mouseDragging = false;
    //   console.log("---------------");
    //   console.log("MouseX: " + cubeRotateX);
    //   console.log("MouseY: " + cubeRotateY);
    //   previousMouseX = null;
    //   previousMouseY = null;
    // }).on("mousemove", function(evt) {
    //   evt.preventDefault();
    //   if (!mouseDragging) { return };
    //   if (previousMouseX && previousMouseY) {
    //     var mouseX, mouseY, relativeX, relativeY;
    //     mouseX = evt.clientX;
    //     mouseY = evt.clientY;
    //     relativeX = (mouseX - previousMouseX) / sensitivityX;
    //     relativeY = (previousMouseY - mouseY) / sensitivityY;
    //     relativeRotate(relativeX, relativeY);
    //   }
    //   previousMouseX = evt.clientX;
    //   previousMouseY = evt.clientY;
    // })

  }
})
