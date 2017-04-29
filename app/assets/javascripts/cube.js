performMove = function(moveString) {
  var direction = moveString[1] == "'" ? "counter-clockwise" : "clockwise";
  var moveCount = moveString[1] == "2" ? 2 : 1;
  var face = moveString[0];
}

$(document).ready(function() {
  // cubeX = 0;
  // cubeY = 50;
  // setInterval(function() {
  //   $('#cube').css({"transform": "rotateX(" + cubeX + "deg) rotateY(" + cubeY + "deg)"});
  //   cubeX += 2;
  //   cubeY += 1;
  // }, 25);
})
