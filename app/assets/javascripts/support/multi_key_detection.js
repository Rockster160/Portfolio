keysPressed = [];

function multiKeyDown(key) {
  if (keysPressed.indexOf(key) == -1) { keysPressed.push(key) };
}
function multiKeyUp(key) {
  keysPressed = keysPressed.filter(function(e) { return e != key });
}

function isKeyPressed(keycode) {
  return keysPressed.indexOf(keycode) != -1
}
