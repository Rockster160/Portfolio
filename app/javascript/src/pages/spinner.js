export function Spinner(opts) {
  opts = opts || {}
  this.width = opts.size || 100
  this.height = opts.size || 100
  this.stroke = opts.stroke || 16
  this.duration = opts.duration || 3000
  this.color = opts.color || "blue"

  this.r = (this.height - this.stroke) / 2
  this.c = Math.PI * (this.r * 2)

  this.element = document.createElementNS('http://www.w3.org/2000/svg', 'svg')
  let c = document.createElementNS('http://www.w3.org/2000/svg', 'circle')
  this.element.setAttribute("width", this.width)
  this.element.setAttribute("height", this.height)
  this.element.setAttribute("stroke-dasharray", this.magic)
  c.setAttribute("viewbox", "0 0" + this.width + " " + this.height)
  c.setAttribute("cx", this.width/2)
  c.setAttribute("cy", this.height/2)
  c.setAttribute("r", this.r)
  c.setAttribute("stroke-width", this.stroke)
  c.setAttribute("stroke", this.color)
  c.setAttribute("fill", "transparent")
  this.element.setAttribute("stroke-dasharray", this.c)
  this.element.setAttribute("stroke-dashoffset", 0)
  this.element.appendChild(c)
  this.element.style.cssText = "position: absolute; left: calc(50% - " + (this.width/2) + "px); top: calc(50% - " + (this.height/2) + "px); transform: rotateZ(-90deg);"

  this.start_ms = undefined
  this.end_ms = undefined
  this.interval = undefined

  return this
}
Spinner.prototype.tick = function() {
  var now = (new Date()).getTime()
  var progress_ms = this.end_ms - now
  var progress = (progress_ms / this.duration)
  if (progress < 0) {
    clearInterval(this.interval)
    progress = 0
  }
  this.element.setAttribute("stroke-dashoffset", progress * this.c)
}
Spinner.prototype.start = function() {
  var spinner = this
  spinner.start_ms = (new Date()).getTime()
  spinner.end_ms = spinner.start_ms + spinner.duration
  clearInterval(spinner.interval)
  spinner.interval = setInterval(function() {
    spinner.tick()
  }, 10)
}
Spinner.prototype.reset = function() {
  clearInterval(this.interval)
  this.start_ms = undefined
  this.end_ms = undefined
  this.element.setAttribute("stroke-dashoffset", 0)
}
Spinner.show = function(opts) {
  var spinner = new Spinner(opts)
  spinner.start()
  return spinner.element
}
// document.body.appendChild(
//   Spinner.show({
//     size: 200,
//     stroke: 10,
//     duration: 1000,
//     color: "#2196F3",
//   })
// )
