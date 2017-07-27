preventKeyEvents = false
keysPressed = [];
$(document).keydown(function(evt) {
  if (keysPressed.indexOf(evt.which) == -1) { keysPressed.push(evt.which) };
  if (preventKeyEvents) {
    evt.preventDefault()
    return false
  }
}).keyup(function(evt) {
  keysPressed = keysPressed.filter(function(e) { return e != evt.which });
  if (preventKeyEvents) {
    evt.preventDefault()
    return false
  }
})

function isKeyPressed(keycode) {
  return keysPressed.indexOf(keycode) != -1
}
