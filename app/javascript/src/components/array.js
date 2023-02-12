Array.prototype.sum = function (array) {
  array.reduce(function(sum, val) { return sum + val }, 0)
}
Array.prototype.eq = function (array) {
  // if the other array is a falsy value, return
  if (!array) { return false }

  // compare lengths - can save a lot of time
  if (this.length != array.length) { return false }

  for (var i=0; i<this.length; i++) {
    // Check if we have nested arrays
    if (this[i] instanceof Array && array[i] instanceof Array) {
      // recurse into the nested arrays
      return this[i].eq(array[i])
    }
    else if (this[i] != array[i]) {
      // Warning - two different object instances will never be equal: {x:20} != {x:20}
      return false
    }
  }
  return true
}
