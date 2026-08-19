import { Text } from "../_text";
import { Time } from "./_time";
import { shiftTempToColor } from "../vars";

(function () {
  var getWeatherEmoji = function (code, isNight) {
    let ico =
      "[ico wi wi-owm-" +
      code +
      " wi-owm-" +
      (isNight ? "night" : "day") +
      "-" +
      code +
      "]";
    return Text.color(isNight ? "#C5C4DE" : "#DEDBBB", ico);
  };

  var getSunEmoji = function (kind) {
    return Text.orange("[ico wi wi-" + kind + "]");
  };

  // Every sunrise/sunset the forecast covers, ascending. `current` only carries
  // today's pair, so the markers have to come from `daily` - and the hourly
  // icons read the same list, so a marker can't contradict the icon beside it.
  var getSunEvents = function (json) {
    var events = [];
    (json.daily || []).forEach(function (day_data) {
      if (day_data.sunrise) {
        events.push({ dt: day_data.sunrise, kind: "sunrise" });
      }
      if (day_data.sunset) {
        events.push({ dt: day_data.sunset, kind: "sunset" });
      }
    });

    return events.sort(function (a, b) {
      return a.dt - b.dt;
    });
  };

  // The most recent sun event at or before the given time decides; earlier than
  // all of them means we're in the night leading up to the first one.
  var isNightAt = function (time_sec, sun_events) {
    var last = null;
    sun_events.forEach(function (evt) {
      if (evt.dt <= time_sec) {
        last = evt;
      }
    });
    if (last) {
      return last.kind == "sunset";
    }

    return sun_events.length > 0 && sun_events[0].kind == "sunrise";
  };

  // The eight hourly columns with any upcoming sun event slotted in between the
  // hours it falls between. The row is 32 characters wide either way, so a
  // marker costs the last hour of forecast rather than overflowing. Past events
  // are skipped - you can already see out the window.
  var getHourlyColumns = function (json, now_sec, sun_events) {
    var columns = json.hourly.slice(0, 8).map(function (hr_data) {
      return { dt: hr_data.dt, hour: hr_data };
    });
    sun_events.forEach(function (evt) {
      if (evt.dt > now_sec) {
        columns.push({ dt: evt.dt, sun: evt.kind });
      }
    });

    return columns
      .sort(function (a, b) {
        return a.dt - b.dt;
      })
      .slice(0, 8);
  };

  let getNextPingTime = function () {
    let next_hour = Time.msUntilNextHour() + Time.seconds(5);
    let ten_minutes = Time.minutes(10);

    return next_hour < ten_minutes ? next_hour : ten_minutes;
  };

  Cell.register({
    title: "Weather",
    text: "Loading...",
    refreshInterval: getNextPingTime(),
    reloader: function () {
      var cell = this;
      cell.refreshInterval = getNextPingTime();

      var url =
        "https://api.openweathermap.org/data/3.0/onecall?lat=40.480476443141924&lon=-111.99818607287183&units=imperial&exclude=minutely,alerts&lang=en&appid=" +
        cell.config.apikey;
      $.getJSON(url).done(function (json) {
        var current = json.current;
        var currentTime = new Date().getTime() / 1000;
        var sun_events = getSunEvents(json);
        var isNight = isNightAt(currentTime, sun_events);
        var now = {
          icon: getWeatherEmoji(current.weather[0].id, isNight),
          temp: Math.round(current.temp),
          description: current.weather[0].description,
          feelsLike: Math.round(current.feels_like),
        };

        var hourly_hours = [],
          hourly_icons = [],
          hourly_temps = [];
        var columns = getHourlyColumns(json, currentTime, sun_events);
        columns.forEach(function (col, idx) {
          var pad = idx == 0 ? 3 : 4;
          var time = Time.at(col.dt);

          if (col.sun) {
            // Only the minutes fit, and the icon says which event it is.
            var minutes = ":" + String(time.getMinutes()).padStart(2, "0");

            hourly_hours.push(Text.orange(minutes.padStart(pad, " ")));
            hourly_icons.push("".padStart(pad - 2, " ") + getSunEmoji(col.sun));
            hourly_temps.push(" ".repeat(pad));
            return;
          }

          var hour = time.getHours();
          if (hour > 12) {
            hour -= 12;
          }
          if (hour == 0) {
            hour = 12;
          }
          var is_night_hour = isNightAt(col.dt, sun_events);
          var icon = getWeatherEmoji(col.hour.weather[0].id, is_night_hour);

          hourly_hours.push(String(hour).padStart(pad, " "));
          hourly_icons.push("".padStart(pad - 2, " ") + icon);
          hourly_temps.push(shiftTempToColor(col.hour.temp, pad));
        });

        var daily_days = [],
          daily_icons = [],
          daily_highs = [],
          daily_lows = [];
        json.daily.slice(0, 7).forEach(function (day_data, idx) {
          var pad = 4;
          var time = Time.at(day_data.dt);
          var icon = getWeatherEmoji(day_data.weather[0].id, false);
          var day_names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

          daily_days.push(day_names[time.getDay()].padStart(pad, " "));
          daily_icons.push("".padStart(pad - 2, " ") + icon);
          daily_highs.push(shiftTempToColor(day_data.temp.max, pad));
          daily_lows.push(shiftTempToColor(day_data.temp.min, pad));
        });

        var lines = [
          Text.center(
            now.description +
              " " +
              now.icon +
              " " +
              shiftTempToColor(now.temp) +
              " (" +
              shiftTempToColor(now.feelsLike) +
              ")",
          ),
          "◴" + hourly_hours.join("").slice(1),
          hourly_icons.join(""),
          " " + hourly_temps.join(""),
          "",
          "  " + daily_days.join(""),
          "  " + daily_icons.join(""),
          "▲  " + daily_highs.join(""),
          "▼  " + daily_lows.join(""),
        ];

        cell.text(lines.join("\n"));
      });
    },
  });
})();
