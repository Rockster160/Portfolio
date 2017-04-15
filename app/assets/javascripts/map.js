$(document).ready(function() {
  if ($('#map').length > 0) {

    // pokeMarkerJs()
    handler = Gmaps.build('Google');
    handler.buildMap(
      {
        provider: {
          disableDefaultUI: true,
          zoom: 17,
        },
        internal: { id: 'map' }
      }, function() {
        // resetMarker(40.539541000405805, -111.98068286310792)
        handler.map.centerOn({
          lat: 40.539541000405805,
          lng: -111.98068286310792
        })
      }
    );
    map = handler.getMap()

    resetMarker = function(latitude, longitude, shouldCenter) {
      if (shouldCenter == undefined) { shouldCenter = true }
      var current_location_marker = handler.addMarker({
        lat: latitude,
        lng: longitude
      }, {
        'animation': google.maps.Animation.DROP,
        'z-index': 10,
        'draggable': true
      })
      google.maps.event.addListener(current_location_marker.getServiceObject(), 'dragend', function() {
        $('#location-field').val(this.position.lat() + ',' + this.position.lng())
      })
      google.maps.event.addListener(current_location_marker.getServiceObject(), 'click', function() {
        handler.removeMarker(current_location_marker)
      })
      $('#location-field').val(latitude + ',' + longitude)
      if (shouldCenter) {
        centerOnMarker(current_location_marker)
      }
    }

    // map.addListener('click', function(e) {
    //   resetMarker(e.latLng.lat(), e.latLng.lng(), false)
    // })

    centerOnMarker = function(current_location_marker) {
      handler.map.centerOn({ lat: current_location_marker.serviceObject.position.lat(), lng: current_location_marker.serviceObject.position.lng() })
    }

    $('.search-btn').click(function() {
      if ($('#location-field').val().length > 0) {
        var geocoder = new google.maps.Geocoder();
        geocoder.geocode({
          address: $('#location-field').val()
        }, function(results, status) {
          if (status == google.maps.GeocoderStatus.OK) {
            var latitude = results[0].geometry.location.lat();
            var longitude = results[0].geometry.location.lng();
            resetMarker(latitude, longitude)
          } else {
            $('.error-container').html('Failed to find location.')
            return false
          }
        })
      }
    })

    $('.location-btn').click(function() {
      getLocation()
    })

    getLocation = function() {
      if (navigator.geolocation) {
        navigator.geolocation.getCurrentPosition(geolocatedPosition)
      } else {
        $('.error-container').html("User denied Geolocation")
      }
    }

    geolocatedPosition = function(position) {
      var lat = position.coords.latitude, lng = position.coords.longitude;
      resetMarker(lat, lng)
      centerOnMarker()
    }
  }

})
