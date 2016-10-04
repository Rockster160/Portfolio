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

  var places = [{address: "13842 S Kyle Earl Ln Herriman, UT ", price: "$289,900", url: "/homes/listing/40069448"}, {address: "10897 S Topview Rd South Jordan, UT ", price: "$269,999", url: "/homes/listing/40068817"}, {address: "668 E WYNGATE POINTE  LN Draper, UT ", price: "$269,900", url: "/homes/listing/40068458"}, {address: "4844 W SO. JORDAN PKWY #658 South Jordan, UT ", price: "$269,900", url: "/homes/listing/40027850"}, {address: "7217 S CAPRINE CT West Jordan, UT ", price: "$259,900", url: "/homes/listing/40064912"}, {address: "7159 W 8090 S West Jordan, UT ", price: "$299,900", url: "/homes/listing/40063230"}, {address: "10207 S YUBA WAY South Jordan, UT ", price: "$279,500", url: "/homes/listing/40062115"}, {address: "16064 S Chimney Stone Rd Draper, UT ", price: "$299,400", url: "/homes/listing/40046742"},{address: "6445 S Fire Sky Ct West Jordan, UT ", price: "$278,900", url: "/homes/listing/40059515"}, {address: "11219 S Crescent Oak Way Sandy, UT ", price: "$290,000", url: "/homes/listing/40059153"}, {address: "12468 S Saquamish St Riverton, UT ", price: "$282,000", url: "/homes/listing/40057418"}, {address: "4472 W Osage Rd Riverton, UT ", price: "$269,900", url: "/homes/listing/40057255"}, {address: "6852 W Grevillea Ln West Jordan, UT ", price: "$234,900", url: "/homes/listing/40050747"}, {address: "10243 S Clarks Hill Dr South Jordan, UT ", price: "$269,900", url: "/homes/listing/40048436"}, {address: "11658 S Oakmond Rd South Jordan, UT ", price: "$288,400", url: "/homes/listing/40022409"}, {address: "6842 W Grevillea Ln West Jordan, UT ", price: "$234,000", url: "/homes/listing/40018798"},{address: "6890 S High Bluff Dr West Jordan, UT ", price: "$280,000", url: "/homes/listing/40008935"}];
  $(places).each(function() {
    var place = this;
    var geocoder = new google.maps.Geocoder();
    geocoder.geocode({
      address: this.address
    }, function(results, status) {
      if (status == google.maps.GeocoderStatus.OK) {
        var latitude = results[0].geometry.location.lat();
        var longitude = results[0].geometry.location.lng();
        var html = '<div><h1><a href="https://www.ksl.com' + place.url + '">' + place.price + '</a></h1><p>' + place.address + '</p></div>'
        handler.addMarker({
          'lat': latitude,
          'lng': longitude,
          'infowindow': html
        })
      }
    })
  })


})




// $('.FavoriteHomeItem-infoHomeDetails').map(function() {
//   var address = $(this).children('.FavoriteHomeItem-infoHomeTitle').text() + ' ' + $(this).children('.FavoriteHomeItem-infoHomeLocation').text().split('|')[0];
//   var price = $(this).children('.FavoriteHomeItem-infoHomePrice').text();
//   var url = $(this).find('.FavoriteHomeItem-infoHomeTitle a').attr('href');
//   return {
//     'address': address,
//     'price': price,
//     'url': url
//   }
// })
