var time_ms = {};
time_ms.second = 1000;
time_ms.minute = 60 * time_ms.second;
time_ms.hour = 60 * time_ms.minute;
time_ms.day = 24 * time_ms.hour;
time_ms.week = 7 * time_ms.day;
time_ms.month = 30 * time_ms.day;
time_ms.year = 12 * time_ms.month;

$("[data-next-occurrence]").ready(function() {
  var occurrence_object = $(this)

  var configureTime = function() {
    var endTime = parseInt(occurrence_object.attr("data-next-occurrence"))
    if (!(endTime > 0)) { return occurrence_object.text("") }
    var currentTime = (new Date()).getTime()
    var timeDiffMs = endTime - currentTime

    var countdown_array = []
    if (timeDiffMs >= time_ms.year) { countdown_array.push([Math.floor(timeDiffMs / time_ms.year), " year"]); timeDiffMs %= time_ms.year }
    if (timeDiffMs >= time_ms.month) { countdown_array.push([Math.floor(timeDiffMs / time_ms.month), " month"]); timeDiffMs %= time_ms.month }
    if (timeDiffMs >= time_ms.week) { countdown_array.push([Math.floor(timeDiffMs / time_ms.week), " week"]); timeDiffMs %= time_ms.week }
    if (timeDiffMs >= time_ms.day) { countdown_array.push([Math.floor(timeDiffMs / time_ms.day), " day"]); timeDiffMs %= time_ms.day }
    if (timeDiffMs >= time_ms.hour) { countdown_array.push([Math.floor(timeDiffMs / time_ms.hour), " hour"]); timeDiffMs %= time_ms.hour }
    if (timeDiffMs >= time_ms.minute) { countdown_array.push([Math.floor(timeDiffMs / time_ms.minute), " minute"]); timeDiffMs %= time_ms.minute }
    if (timeDiffMs >= time_ms.second) { countdown_array.push([Math.floor(timeDiffMs / time_ms.second), " second"]); timeDiffMs %= time_ms.second }

    if (countdown_array.length > 0) {
      occurrence_object.text("Resets in " + countdown_array.map(function(t) { return t[0] + t[1] + (t[0] != 1 ? "s" : "") }).join(", ") + " from now.")
    } else {
      occurrence_object.text("")
    }
  }
  configureTime()
  setInterval(configureTime, 1000)
})
