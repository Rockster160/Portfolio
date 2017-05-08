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

})
