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

  $(document).keydown(function(evt) {
    if ($('.hover-highlight').length > 0) {
      sticker = $('.hover-highlight');
      dom_cubelet = sticker.parents('.cubelet');
      // cubelet = cube.cubelets[getCubeletIdFromDomCubelet(dom_cubelet)];
      dom_cubelet.trigger("mousedown", { clientX: dom_cubelet.offset().left, clientY: dom_cubelet.offset().top })
    }
  })

  // white: 0, 0, 0
  // orange: 90, 0, 0
  // red: 270, 0, 0
  // yellow: 180, 0, 0

})

getCubeletIdFromDomCubelet = function(dom_cubelet) {
  var cubelet_id_class = dom_cubelet.attr("class").match(/cubeletId-\d+/)[0]
  return cubelet_id_class.match(/\d+/);
}

performMove = function(moveString) {
  var direction = moveString[1] == "'" ? "counter-clockwise" : "clockwise";
  var moveCount = moveString[1] == "2" ? 2 : 1;
  var face = moveString[0];
}
