import { Text } from "../_text"
import { Time } from "./_time"
import { ColorGenerator } from "./color_generator"

(function() {
  var getWeatherEmoji = function(code, isNight) {
    if (code >= 200 && code < 300 || code == 960 || code == 961) {
      return Emoji.cloud_with_lightning_and_rain
    } else if ((code >= 300 && code < 600) || code == 701) {
      return Emoji.cloud_with_rain
    } else if (code >= 600 && code < 700) {
      return Emoji.snowflake
    } else if (code == 711) {
      return Emoji.fire
    } else if (code == 800) {
      return isNight ? Emoji.full_moon : Emoji.sunny
    } else if (code == 801) {
      return isNight ? Emoji.cloud : Emoji.sun_behind_small_cloud
    } else if (code == 802) {
      return isNight ? Emoji.cloud : Emoji.sun_behind_med_cloud
    } else if (code == 803) {
      return isNight ? Emoji.cloud : Emoji.sun_behind_large_cloud
    } else if (code == 804) {
      return Emoji.cloud
    } else if (code == 900 || code == 962 || code == 781) {
      return Emoji.tornado
    } else if (code >= 700 && code < 800) {
      return Emoji.fog
    } else if (code == 903) {
      return Emoji.cold
    } else if (code == 904) {
      return Emoji.hot
    } else if (code == 905 || code == 957) {
      return Emoji.dash
    } else if (code == 906 || code == 958 || code == 959) {
      return Emoji.ice
    } else {
      console.log("Unknown code", code);
      return Emoji.question
    }
  }

  let tempScale = function(temp1, temp2) {
    return temp2 - temp1
  }

  let color_shift = [
    ...ColorGenerator.fadeBetweenHex("#00F", "#FFF", tempScale(5, 32)),
    ...ColorGenerator.fadeBetweenHex("#FFF", "#FF0", tempScale(32, 70)),
    ...ColorGenerator.fadeBetweenHex("#FF0", "#F00", tempScale(70, 96)),
  ]

  let scaleVal = function(value, f1, f2, t1, t2) {
    var tr = t2 - t1
    var fr = f2 - f1

    return (value - f1) * tr / fr + t1
  }

  let shiftTempToColor = function(temp, pad) {
    let min_temp = 5, max_temp = 96
    let scaled_idx = scaleVal(temp, min_temp, max_temp, 0, color_shift.length - 1)
    let constrained_idx = [Math.round(scaled_idx), 0, color_shift.length - 1].sort(function(a, b) {
      return a - b
    })[1]
    let color = color_shift[constrained_idx]
    let str = Math.round(temp) + "°"

    return Text.color(color.hex, str.padStart(pad, " "))
  }

  Cell.register({
    title: "Weather",
    text: "Loading...",
    refreshInterval: Time.msUntilNextHour() + Time.seconds(5),
    reloader: function() {
      var cell = this
      cell.refreshInterval = Time.msUntilNextHour() + Time.seconds(5)

      var url = "https://api.openweathermap.org/data/2.5/onecall?lat=40.480476443141924&lon=-111.99818607287183&units=imperial&exclude=minutely,alerts&lang=en&appid=" + cell.config.apikey
      $.getJSON(url).done(function(json) {
        var current = json.current
        var currentTime = new Date().getTime() / 1000;
        var isNight = currentTime >= current.sunset || currentTime <= current.sunrise
        var now = {
          icon: getWeatherEmoji(current.weather[0].id, isNight),
          temp: Math.round(current.temp),
          description: current.weather[0].description,
          feelsLike: Math.round(current.feels_like),
        }

        var hourly_hours = [], hourly_icons = [], hourly_temps = []
        json.hourly.slice(0, 8).forEach(function(hr_data, idx) {
          var pad = idx == 0 ? 3 : 4
          var time = Time.at(hr_data.dt)
          // This day/night check might be weird overnight
          var hour = time.getHours()
          if (hour > 12) { hour -= 12 }
          if (hour == 0) { hour = 12 }
          var is_night_hour = time >= current.sunset || time <= current.sunrise
          var icon = getWeatherEmoji(hr_data.weather[0].id, is_night_hour)

          hourly_hours.push(String(hour).padStart(pad, " "))
          hourly_icons.push("".padStart(pad - 2, " ") + icon)
          hourly_temps.push((shiftTempToColor(hr_data.temp, pad)))
        })

        var daily_days = [], daily_icons = [], daily_highs = [], daily_lows = []
        json.daily.slice(0, 7).forEach(function(day_data, idx) {
          var pad = 4
          var time = Time.at(day_data.dt)
          var icon = getWeatherEmoji(day_data.weather[0].id, false)
          var day_names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

          daily_days.push(day_names[time.getDay()].padStart(pad, " "))
          daily_icons.push("".padStart(pad - 2, " ") + icon)
          daily_highs.push((shiftTempToColor(day_data.temp.max, pad)))
          daily_lows.push((shiftTempToColor(day_data.temp.min, pad)))
        })

        var lines = [
          Text.center(now.description + " " + now.icon + " " + now.temp + "° (" + now.feelsLike + ")"),
          "◴" + hourly_hours.join("").slice(1),
          hourly_icons.join(""),
          " " + hourly_temps.join(""),
          "",
          "  " + daily_days.join(""),
          "  " + daily_icons.join(""),
          "▲  " + daily_highs.join(""),
          "▼  " + daily_lows.join(""),
        ]

        cell.text(lines.join("\n"))
      })
    },
  })
})()
