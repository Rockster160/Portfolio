keysPressed = [];

export function multiKeyDown(key) {
  if (keysPressed.indexOf(key) == -1) { keysPressed.push(key) };
}
export function multiKeyUp(key) {
  keysPressed = keysPressed.filter(function(e) { return e != key });
}

export function isKeyPressed(keycode) {
  return keysPressed.indexOf(keycode) != -1
}
