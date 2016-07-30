last_update = 0;
pokeTimer = null;
poke_markers = [];
current_location_marker = null;

$(document).ready(function() {
  if ($('#map').length > 0) {

    pokeMarkerJs()
    handler = Gmaps.build('Google');
    handler.buildMap(
      {
        provider: {
          disableDefaultUI: true,
          zoom: 17,
        },
        internal: { id: 'map' }
      }, function() {
        resetMarker(currentPosition().latitude, currentPosition().longitude)
      }
    );
    map = handler.getMap()

    resetMarker = function(latitude, longitude) {
      if (current_location_marker != undefined) {
        handler.removeMarker(current_location_marker)
      }
      current_location_marker = handler.addMarker({
        lat: latitude,
        lng: longitude
      }, {
        'animation': google.maps.Animation.DROP,
        'z-index': 10,
        'draggable': true
      })
      google.maps.event.addListener(current_location_marker.getServiceObject(), 'dragend', function() {
        $('#location-field').val(this.position.lat() + ',' + this.position.lng())
        setLocation(this.position.lat(), this.position.lng())
      })
      setLocation(latitude, longitude)
      $('#location-field').val(latitude + ',' + longitude)
      centerOnMarker()
    }

    setLocation = function(lat, lng) {
      $('.pokemon-list-container').attr('data-latitude', lat)
      $('.pokemon-list-container').attr('data-longitude', lng)
    }

    centerOnMarker = function() {
      handler.map.centerOn({ lat: current_location_marker.serviceObject.position.lat(), lng: current_location_marker.serviceObject.position.lng() })
    }

    findPokemonByDbId = function(db_id) {
      var marker = null;
      $(poke_markers).each(function() {
        if (parseInt(this.args.db_id) == parseInt(db_id)) {
          marker = this;
        }
      })
      return marker;
    }

    removePokemonFromMap = function(marker) {
      if (marker != null) {
        poke_markers = poke_markers.filter(function() {return this != marker})
        marker.remove()
      }
    }

    updatePokemonOnMap = function() {
      var expired_marker_ids = $(poke_markers).map(function() {return this.args.db_id})
      $('.pokemon-container').each(function() {
        var db_id = $(this).attr('data-db-id'), marker = findPokemonByDbId(db_id);
        if (marker == null) {
          var lat = $(this).attr('data-lat'),
            lng = $(this).attr('data-lng'),
            poke_id = $(this).attr('data-poke-id')
          addPokemon(lat, lng, poke_id, db_id)
        } else {
          expired_marker_ids = expired_marker_ids.filter(function() {return this != marker.args.db_id})
        }
      })
      $(expired_marker_ids).each(function() {
        var id = parseInt(this)
        marker = findPokemonByDbId(id)
        removePokemonFromMap(marker)
      })
    }

    addPokemon = function(lat, lng, poke_id, db_id) {
      var myLatLng = new google.maps.LatLng(lat, lng)
      var poke_marker = new PokeMarker(myLatLng, map, {poke_id: poke_id, db_id: db_id})
      poke_markers.push(poke_marker)
    }

    dropPin = function(lat, lng) {
      handler.addMarker( { 'lat': lat, 'lng': lng }, { 'animated': true, 'draggable': true } )
    }

    setClocks = function() {
      if ($('.poke-page').length > 0) {
        pokeTimer = setInterval(function() {
          console.log("tick");
          checkPokemon()
          updatePokemonOnMap()
          updateCounters()
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

    remainingToTimer = function(remaining) {
      var words = [], minutes = '', seconds = '';

      minutes = remaining.minutes < 10 ? '0' + remaining.minutes : remaining.minutes;
      seconds = remaining.seconds < 10 ? '0' + remaining.seconds : remaining.seconds;
      words.push(minutes);
      words.push(seconds);
      return words.join(':')
    }

    function updateCounters() {
      $('.countdown').each(function() {
        var endsAt = $(this).attr('data-countdown-to') * 1000;
        var remaining = getTimeRemaining(endsAt);
        if (remaining.total <= 0) {
          $(this).parents('.pokemon-container').remove();
        } else {
          var poke_marker = pokemonFromContainer($(this).parents('.pokemon-container'))
          if (poke_marker != undefined) {
            $(poke_marker.div).find('.poke-timer').html(remainingToTimer(remaining))
          }
          var words = remainingToWords(remaining);
          $(this).html(words);
        }
      })
    }

    $('.scan').click(function() {
      if ($(this).hasClass('scanning')) {
      } else {
        scan();
        $('.scan').addClass('scanning');
        $('.scan').html('Scanning...')
        setTimeout(function() {
          $('.scan').removeClass('scanning');
          $('.scan').html('SCAN')
        }, 30000)
      }
    })

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

    currentPosition = function() {
      return {
        'latitude': $('.pokemon-list-container').attr('data-latitude'),
        'longitude': $('.pokemon-list-container').attr('data-longitude')
      }
    }

    scan = function() {
      var lat = current_location_marker.serviceObject.position.lat(),
      lng = current_location_marker.serviceObject.position.lng(),
      loc = lat + ',' + lng;
      $.post('/scan', {loc: loc})
    }

    pokemonFromContainer = function(container) {
      var db_id = $(container).attr('data-db-id');
      return findPokemonByDbId(db_id)
    }

    checkPokemon = function() {
      $.get('/pokemon_list', {since: last_update}).done(function(data) {
        var temp_container = $('<div/>').addClass('hidden')
        $('body').append(temp_container)
        temp_container.html(data)

        var all_pokemon = $('.pokemon-container'),
        uniq_pokemon = getUniqPokemon(all_pokemon);
        temp_container.html(uniq_pokemon)
        $('.pokemon-list-container').html('')
        updatePokemonDistance()
        var sortedPokemon = getSortedPokemon(uniq_pokemon)
        $('.pokemon-list-container').html(sortedPokemon)
        temp_container.remove()
        updatePokemonOnMap()
      })
      last_update = (new Date()).getTime()
    }

    getUniqPokemon = function(pokemon) {
      var found = {};
      return pokemon.filter(function() {
        var pokemon_database_id = $(this).attr('data-db-id');
        if (found[pokemon_database_id]) {
          return false
        } else {
          found[pokemon_database_id] = true;
          return true
        }
      })
    }

    getSortedPokemon = function(pokemon) {
      return pokemon.toArray().sort(function(a, b) {
        return $(a).attr('data-distance') - $(b).attr('data-distance');
      })
    }

    updatePokemonDistance = function() {
      pos = currentPosition()
      lat = pos.latitude
      lng = pos.longitude

      $('.pokemon-container').each(function() {
        if (!lat || !lng) { return }
        var poke_lat = $(this).attr('data-lat'), poke_lng = $(this).attr('data-lng');
        var distance = distanceBetween(lat, lng, poke_lat, poke_lng), bearing = calcBearing(lat, lng, poke_lat, poke_lng);
        $(this).attr('data-distance', distance);
        $(this).find('.relative-bearing').html((Math.round(bearing * 100) / 100) + 'º ' + (Math.round(distance * 100) / 100) + 'ft');
        $(this).find('.relative-directions').html(directionStr(lat, lng, poke_lat, poke_lng));
      })
    }

    calcBearing = function(from_lat, from_lng, to_lat, to_lng) {
      from_lat = parseFloat(from_lat)
      from_lng = parseFloat(from_lng)
      to_lat = parseFloat(to_lat)
      to_lng = parseFloat(to_lng)
      var delta_lng = (from_lng - to_lng)
      var y = Math.sin(delta_lng) * Math.cos(to_lat)
      var x = Math.cos(from_lat) * Math.sin(to_lat) - Math.sin(from_lat) * Math.cos(to_lat) * Math.cos(delta_lng)

      var brng = Math.atan2(y, x)

      brng = (180 / Math.PI) * brng // rad to deg
      brng = (brng + 360) % 360
      brng = 360 - brng

      return brng// º
    }

    distanceBetween = function(lat1, lng1, lat2, lng2) {
      lat1 = parseFloat(lat1)
      lng1 = parseFloat(lng1)
      lat2 = parseFloat(lat2)
      lng2 = parseFloat(lng2)
      var radlat1 = Math.PI * lat1/180
      var radlat2 = Math.PI * lat2/180
      var theta = lng1-lng2
      var radtheta = Math.PI * theta/180
      var dist = Math.sin(radlat1) * Math.sin(radlat2) + Math.cos(radlat1) * Math.cos(radlat2) * Math.cos(radtheta);
      dist = Math.acos(dist)
      dist = dist * 180/Math.PI
      dist = dist * 60 * 1.1515 // miles
      dist = dist * 1.609344 // kilometers
      dist = dist * 3280.84 // feet
      return dist
    }

    directionStr = function(from_lat, from_lng, to_lat, to_lng) {
      // N = + Lat
      // E = + Lng
      // S = - Lat
      // W = - Lng
      var lat_distance = distanceBetween(from_lat, from_lng, to_lat, from_lng)
      var lng_distance = distanceBetween(from_lat, from_lng, from_lat, to_lng)
      var lat_cardinal_direction = from_lat < to_lat ? 'N' : 'S'
      var lng_cardinal_direction = from_lng < to_lng ? 'W' : 'E'
      var lat_distance_str = (Math.round(lat_distance * 100) / 100) + 'ft ' + lat_cardinal_direction
      var lng_distance_str = (Math.round(lng_distance * 100) / 100) + 'ft ' + lng_cardinal_direction
      return [lat_distance_str, lng_distance_str].join(', ')
    }

    setTimeout(function() {
      updatePokemonDistance();
      updateCounters();
    }, 1000)
    setClocks()
  }
})
