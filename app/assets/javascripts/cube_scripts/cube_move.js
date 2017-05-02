const KEY_EVENT_LEFT = 37,
      KEY_EVENT_UP = 38,
      KEY_EVENT_DOWN = 40,
      KEY_EVENT_RIGHT = 39;

$(document).ready(function() {

  rotate = function(x, y, z) { cube.rotation.set(y * Math.PI / 180, x * Math.PI / 180, z * Math.PI / 180) }
  rotate(-45, 25, 0)

  $(document).on("mouseenter", ".sticker", function() {
    $(this).addClass("hover-highlight");
  }).on("mouseleave", ".sticker", function() {
    $(this).removeClass("hover-highlight");
  })

  $(document).keydown(function() {
    if ($('.hover-highlight').length > 0) {
      sticker = $('.hover-highlight');
      cubelet = sticker.parents('.cubelet');
      possibleSlices  = [ cube.slices[ cubelet.addressX + 1 ], cube.slices[ cubelet.addressY + 4 ], cube.slices[ cubelet.addressZ + 7 ]];
      debugger
    }
  })

  // white: 0, 0, 0
  // orange: 90, 0, 0
  // red: 270, 0, 0
  // yellow: 180, 0, 0

})

performMove = function(moveString) {
  var direction = moveString[1] == "'" ? "counter-clockwise" : "clockwise";
  var moveCount = moveString[1] == "2" ? 2 : 1;
  var face = moveString[0];
}
