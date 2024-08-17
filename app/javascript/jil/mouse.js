export default class Mouse {
  static x
  static y
}

document.addEventListener("mousemove", function(evt) {
  Mouse.x = evt.clientX
  Mouse.y = evt.clientY
})
