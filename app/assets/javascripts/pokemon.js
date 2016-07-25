is_scanning = true;
last_update = 0;
$(document).ready(function() {

  if ($('.countdown').length > 0) {
    pokeTimer = setInterval(function() {
      countDown()
    }, 1000)
    locationTimer = setInterval(function() {
      sortByDistance()
    }, 5000)
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

  countDown = function() {
    $('.countdown').each(function() {
      var endsAt = $(this).attr('data-countdown-to') * 1000;
      var remaining = getTimeRemaining(endsAt);
      if (remaining.total < 0) {
        // $(this).parents('.pokemon-container').remove();
      } else {
        var words = remainingToWords(remaining);
        $(this).html(words);
      }
    })
  }

  $('.scan').click(function() {
    getLocation();
    scan();
    $(this).addClass('hidden');
  })

  getLocation = function() {
    if (navigator.geolocation) {
      navigator.geolocation.getCurrentPosition(updatePosition)
    } else {
      $('.error-container').html("Error!")
    }
  }

  updatePosition = function(position) {
    $('.pokemon-list-container').attr('data-latitude', position.coords.latitude)
    $('.pokemon-list-container').attr('data-longitude', position.coords.longitude)
  }

  currentPosition = function() {
    return {
      'latitude': $('.pokemon-list-container').attr('data-latitude'),
      'longitude': $('.pokemon-list-container').attr('data-longitude')
    }
  }

  scan = function() {
    pos = currentPosition()
    $('.error-container').html("Latitude: " + pos.latitude + "<br>Longitude: " + pos.longitude + "<br><span class=\"scan-progress\">Scanning.... Please Wait</span>")
    $.post('/scan', {lat: pos.latitude, lon: pos.longitude}).always(function() {
      is_scanning = true;
      last_update = new Date();
      pollScan();
    })
  }

  pollScan = function() {
    if (!is_scanning) { return true; }
    setTimeout(function() {
      $.get('/recently_updated', {}).success(function(data) {
        console.log("completed update check");
        // data.last_updated * 1000 > last_update
        if (!data.still_updating) {
          is_scanning = false
          $.get('/pokemon_list', {}).done(function(data) {
            $('.error-container').html('')
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
    var lon_cardinal_direction = from_lon < to_lon ? 'E' : 'W'
    var lat_distance_str = (Math.round(lat_distance * 100) / 100) + 'ft ' + lat_cardinal_direction
    var lon_distance_str = (Math.round(lon_distance * 100) / 100) + 'ft ' + lon_cardinal_direction
    return [lat_distance_str, lon_distance_str].join(', ')
  }

  countDown();
  getLocation();
  setTimeout(function() {
    sortByDistance();
  }, 500)
})
