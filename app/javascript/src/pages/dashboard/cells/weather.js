import { Text } from "../_text"
import { Time } from "./_time"
import { ColorGenerator } from "./color_generator"

(function() {
  var getWeatherEmoji = function(code, isNight) {
    return "[ico wi wi-owm-" + code + " wi-own-" + (isNight ? "night" : "day") + "-" + code + "]"
  }

  let color_scale = ColorGenerator.colorScale({
    "#5B6EE1": 5,
    "#639BFF": 32,
    "#99E550": 64,
    "#FBF236": 78,
    "#AC3232": 96,
  })

  let shiftTempToColor = function(temp, pad) {
    let color = color_scale(temp)
    let str = Math.round(temp) + "°"

    return Text.color(color.hex, str.padStart(pad || 0, " "))
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
          Text.center(now.description + " " + now.icon + " " + shiftTempToColor(now.temp) + " (" + shiftTempToColor(now.feelsLike) + ")"),
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
