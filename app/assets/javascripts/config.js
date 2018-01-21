$(document).ready(function() {

  $('.no-zoom').bind('touchend', function(evt) {
    evt.preventDefault();
    // This is a hack that prevents default browsers from zooming in when
    //   double-clicking elements when preventing the default behavior of a click,
    //   but then calling the normal click action on the element to trigger other
    //   events or click actions.
    $(this).click();
    return false;
  })

  compareArray = function(arr1, arr2) {
    if (arr1.length != arr2.length) { return false }
    return arr1.every(function(itm, idx) {
      return itm == arr2[idx]
    })
  }

  includeArray = function(bigArr, smallArr) {
    if (bigArr.length == 0) { return false }
    return bigArr.some(function(itm) {
      return compareArray(itm, smallArr)
    })
  }

})
