is_scanning = true;
last_update = 0;
pokeTimer = null;
locationTimer = null;
poke_markers = [];
current_location_marker = null;

$(document).ready(function() {
  if ($('#map').length > 0) {

    handler = Gmaps.build('Google');
    handler.buildMap(
      {
        provider: {
          disableDefaultUI: true,
          zoom: 17,
        },
        internal: { id: 'map' }
      }, function() {
        current_location_marker = handler.addMarker({
          "lat": currentPosition().latitude,
          "lng": currentPosition().longitude
        }, {
          'z-index': 10,
          'draggable': true
        })
        handler.map.centerOn({ lat: current_location_marker.serviceObject.position.lat(), lng: current_location_marker.serviceObject.position.lng() })

        google.maps.event.addListener(current_location_marker.getServiceObject(), 'dragend', function() {
          $('.input-location').val(this.position.lat() + ',' + this.position.lng())
        })
      }
    );

    findMarkerByDbId = function(db_id) {
      var marker = null;
      $(poke_markers).each(function() {
        if (parseInt(this.serviceObject.db_id) == parseInt(db_id)) {
          marker = this;
        }
      })
      return marker;
    }

    removeMarkerFromMap = function(marker) {
      if (marker != null) {
        poke_markers = poke_markers.filter(function() {return this != marker})
        marker.clear()
        handler.removeMarker(marker)
      }
    }

    updatePokemonOnMap = function() {
      var expired_marker_ids = $(poke_markers).map(function() {return this.serviceObject.db_id})
      $('.pokemon-container').each(function() {
         var db_id = $(this).attr('data-db-id'), marker = findMarkerByDbId(db_id);
         if (marker == null) {
           var poke_marker = handler.addMarker({
             "lat": $(this).attr('data-lat'),
             "lng": $(this).attr('data-lon'),
             'picture': {
               'url': 'http://pokeapi.co/media/sprites/pokemon/' + $(this).attr('data-poke-id') + '.png',
               'width': 100,
               'height': 100
             }
           })
           poke_marker.serviceObject.set('db_id', db_id)
           poke_markers.push(poke_marker)
         } else {
           expired_marker_ids = expired_marker_ids.filter(function() {return this != marker.serviceObject.db_id})
         }
      })
      $(expired_marker_ids).each(function() {
        marker = findMarkerByDbId(this)
        debugger
        console.log(this);
        removeMarkerFromMap(marker)
      })
    }

    dropPin = function(lat, lon) {
      handler.addMarker(
        {
          'lat': lat,
          'lng': lon
        },
        {
          'animated': true,
          'draggable': true
        }
      )
    }

      setClocks = function() {
        if ($('.countdown').length > 0) {
          pokeTimer = setInterval(function() {
            countDown()
            updatePokemonOnMap()
          }, 1000)
        }
      }

      getTimeRemaining = function(endtime) {
        var t = endtime - Date.parse(new Date());
        var seconds = Math.floor( (t/1000) % 60 );
        var minutes = Math.floor( (t/1000/60) % 60 );
        var hours = Math.floor( (t/(1000*60*60)) % 24 );
        var days = Math.floor( t/(1000*60*60*24) );
        return {
          'total': t,
          'days': days,
          'hours': hours,
          'minutes': minutes,
          'seconds': seconds
        };
      }

      remainingToWords = function(remaining) {
        var words = [];
        if (remaining.days == 1) { words.push(remaining.days + " day") }
        else if (remaining.days > 1) { words.push(remaining.days + " days") }
        if (remaining.hours == 1) { words.push(remaining.hours + " hour") }
        else if (remaining.hours > 1) { words.push(remaining.hours + " hours") }
        if (remaining.minutes == 1) { words.push(remaining.minutes + " minute") }
        else if (remaining.minutes > 1) { words.push(remaining.minutes + " minutes") }
        if (remaining.seconds == 1) { words.push(remaining.seconds + " second") }
        else if (remaining.seconds > 1) { words.push(remaining.seconds + " seconds") }
        return words.join(", ");
      }

      function countDown() {
        $('.countdown').each(function() {
          var parentUid = $(this).parents('.pokemon-container').attr('db_id')
          var endsAt = $(this).attr('data-countdown-to') * 1000;
          var remaining = getTimeRemaining(endsAt);
          if (remaining.total <= 0) {
            var marker = findMarkerByDbId(parentUid)
            removeMarkerFromMap(marker)
            $(this).parents('.pokemon-container').remove();
          } else {
            var words = remainingToWords(remaining);
            $(this).html(words);
          }
        })
      }

      $('.scan').click(function() {
        getLocation();
        // scan();
        // $(this).addClass('hidden');
      })

      getLocation = function() {
        // if (navigator.geolocation) {
          navigator.geolocation.getCurrentPosition(geolocatePosition)
        // } else {
        //   $('.error-container').html("Error!")
        // }
      }

      geolocatePosition = function(position) {
        dropPin(position.coords.latitude, position.coords.longitude)
        // $('.pokemon-list-container').attr('data-latitude', position.coords.latitude)
        // $('.pokemon-list-container').attr('data-longitude', position.coords.longitude)
      }

      currentPosition = function() {
        return {
          'latitude': $('.pokemon-list-container').attr('data-latitude'),
          'longitude': $('.pokemon-list-container').attr('data-longitude')
        }
      }

      scan = function() {
        $.get('/pokemon_list', {}).done(function(data) {
          $('.pokemon-list-container').html(data)
          // getLocation()
          sortByDistance()
        })
        // pos = currentPosition()
        // $('.error-container').html("Latitude: " + pos.latitude + "<br>Longitude: " + pos.longitude + "<br><span class=\"scan-progress\">Scanning.... Please Wait</span>")
        // var location = $('.input-location').val()
        // var loc = location.length > 0 ? location : (pos.latitude + ',' + pos.longitude)
        // $.post('/scan', {loc: loc}).always(function() {
        //   is_scanning = true;
        //   last_update = new Date();
        //   pollScan();
        // })
      }

      pollScan = function() {
        if (!is_scanning) { return true; }
        setTimeout(function() {
          $.get('/recently_updated', {}).success(function(data) {
            if (!data.still_updating) {
              is_scanning = false
              var twenty_seconds_ago = (new Date()).getTime() - 20000
              var failed_to_update = data.last_updated * 1000 > twenty_seconds_ago
              $.get('/pokemon_list', {}).done(function(data) {
                if (failed_to_update) {
                  $('.error-container').html('Trouble connecting to Pokemon Servers')
                } else {
                  $('.error-container').html('')
                }
                $('.scan').removeClass('hidden')
                $('.pokemon-list-container').html(data)
                getLocation()
                sortByDistance()
              })
            }
            pollScan()
          })
        }, 5000)
      }

      sortByDistance = function(lat, lon) {
        pos = currentPosition()
        lat = lat || pos.latitude
        lon = lon || pos.longitude

        $('.pokemon-container').each(function() {
          if (!lat || !lon) { return }
          var poke_lat = $(this).attr('data-lat'), poke_lon = $(this).attr('data-lon');
          var distance = distanceBetween(lat, lon, poke_lat, poke_lon), bearing = calcBearing(lat, lon, poke_lat, poke_lon);
          $(this).attr('data-distance', distance);
          $(this).find('.relative-bearing').html((Math.round(bearing * 100) / 100) + 'º ' + (Math.round(distance * 100) / 100) + 'ft');
          $(this).find('.relative-directions').html(directionStr(lat, lon, poke_lat, poke_lon));
        })

        $('.pokemon-list-container').html(getSortedPokemon())
        updatePokemonOnMap()
      }

      getSortedPokemon = function() {
        return $('.pokemon-container').toArray().sort(function(a, b) {
          return $(a).attr('data-distance') - $(b).attr('data-distance');
        })
      }

      distanceBetween = function(lat1, lon1, lat2, lon2) {
        var radlat1 = Math.PI * lat1/180
        var radlat2 = Math.PI * lat2/180
        var theta = lon1-lon2
        var radtheta = Math.PI * theta/180
        var dist = Math.sin(radlat1) * Math.sin(radlat2) + Math.cos(radlat1) * Math.cos(radlat2) * Math.cos(radtheta);
        dist = Math.acos(dist)
        dist = dist * 180/Math.PI
        dist = dist * 60 * 1.1515 // miles
        dist = dist * 1.609344 // kilometers
        dist = dist * 3280.84 // feet
        return dist
      }

      calcBearing = function(from_lat, from_lon, to_lat, to_lon) {
        var delta_lon = (from_lon - to_lon)
        var y = Math.sin(delta_lon) * Math.cos(to_lat)
        var x = Math.cos(from_lat) * Math.sin(to_lat) - Math.sin(from_lat) * Math.cos(to_lat) * Math.cos(delta_lon)

        var brng = Math.atan2(y, x)

        brng = (180 / Math.PI) * brng // rad to deg
        brng = (brng + 360) % 360
        brng = 360 - brng

        return brng// º
      }

      directionStr = function(from_lat, from_lon, to_lat, to_lon) {
        // N = + Lat
        // E = + Lon
        // S = - Lat
        // W = - Lon
        var lat_distance = distanceBetween(from_lat, from_lon, to_lat, from_lon)
        var lon_distance = distanceBetween(from_lat, from_lon, from_lat, to_lon)
        var lat_cardinal_direction = from_lat < to_lat ? 'N' : 'S'
        var lon_cardinal_direction = from_lon < to_lon ? 'W' : 'E'
        var lat_distance_str = (Math.round(lat_distance * 100) / 100) + 'ft ' + lat_cardinal_direction
        var lon_distance_str = (Math.round(lon_distance * 100) / 100) + 'ft ' + lon_cardinal_direction
        return [lat_distance_str, lon_distance_str].join(', ')
      }

      countDown();
      getLocation();
      setTimeout(function() {
        sortByDistance();
      }, 1000)
      setClocks()

  }
})


// {
//   "lat": 40.53793474945806,
//   "lng": -111.97962070833802,
//   "picture": {
//     "url": "http://people.mozilla.com/~faaborg/files/shiretoko/firefoxIcon/firefox-32.png",
//     "width":  32,
//     "height": 32
//   },
//   "infowindow": "hello!"
// }
// http://pokeapi.co/media/sprites/pokemon/43.png
