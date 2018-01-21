function Queue() {
  this.queue = []
  this.eventCurrentlyRunning = false
}

Queue.finish = function(queue) {
  return (function() {
    queue.eventCurrentlyRunning = false
  })
}

Queue.delay = function(queue, ms) {
  return (function() {
    setTimeout(function() { Queue.finish(queue) }, ms)
  })
}

Queue.prototype.run = function() {
  if (!this.eventCurrentlyRunning) {
    if (this.queue.length == 0) { return clearInterval(this.runningQueue) }
    var nextEvent = this.queue.shift()
    this.eventCurrentlyRunning = true
    nextEvent(this)
  }
}

Queue.prototype.add = function(queued_function) {
  this.queue.push(queued_function)
}

Queue.prototype.delay = function(ms) {
  this.add(Queue.delay(this, ms))
}

Queue.prototype.finish = function(ms) {
  this.eventCurrentlyRunning = false
}

Queue.prototype.process = function() {
  if (this.eventCurrentlyRunning) { return false }
  var q = this
  this.runningQueue = setInterval(function() { q.run() }, 1)
}
