$(document).ready(function() {

  $('.scan').click(function() {
    getLocation();
    $(this).remove();
  })

  getLocation = function() {
    if (navigator.geolocation) {
      navigator.geolocation.getCurrentPosition(showPosition)
    } else {
      $('.error-container').html("Error!")
    }
  }

  showPosition = function(position) {
    $('.error-container').html("Latitude: " + position.coords.latitude + "<br>Longitude: " + position.coords.longitude + "<br>Scanning.... Please Wait")
    $.post('/scan', {lat: position.coords.latitude, lon: position.coords.longitude}).success(function() {
      $('.error-container').append("<h2>Scan Complete! Reload to see the Pokemon<h2>")
    })
  }

})
