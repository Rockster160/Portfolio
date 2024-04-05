export function Time() {}
Time.now = function() { return new Date() }
Time.msSinceEpoch = function() { return Time.now().getTime() }
Time.seconds = Time.second = function(n) { return n === 0 ? 0 : (n || 1) * 1000 }
Time.minutes = Time.minute = function(n) { return n === 0 ? 0 : Time.seconds((n || 1) * 60) }
Time.hours = Time.hour = function(n) { return n === 0 ? 0 : Time.minutes((n || 1) * 60) }
Time.days = Time.day = function(n) { return n === 0 ? 0 : Time.hours((n || 1) * 24) }
Time.weeks = Time.week = function(n) { return n === 0 ? 0 : Time.days((n || 1) * 7) }
Time.fromNow = function(duration_ms, now) {
  now = now || Time.msSinceEpoch()
  return Time.at(now + duration_ms)
}
Time.ago = function(duration_ms, now) {
  now = now || Time.msSinceEpoch()
  return Time.at(now - duration_ms)
}
Time.at = function(epoch) {
  var date = new Date()
  if (epoch < 9999999999) { epoch *= 1000 }

  date.setTime(epoch)
  return date
}
Time.msUntilNextSec = function(now) {
  now = now || Time.now()

  return 1000 - now.getMilliseconds()
}
Time.msUntilNextMinute = function(now) {
  now = now || Time.now()

  return (60 - now.getSeconds() - 1) * Time.second() + Time.msUntilNextSec(now)
}
Time.msUntilNextHour = function(now) {
  now = now || Time.now()

  return (60 - now.getMinutes() - 1) * Time.minute() + Time.msUntilNextMinute(now)
}
Time.msUntilNextDay = function(now) {
  now = now || Time.now()

  return (24 - now.getHours() - 1) * Time.hour() + Time.msUntilNextHour(now)
}
Time.beginningOfDay = function(now) {
  now = now || Time.now()

  return now.setHours(0, 0, 0, 0)
}
Time.endOfDay = function(now) {
  now = now || Time.now()

  return now.setHours(23, 59, 59, 999)
}
Time.duration = function(ms) {
  let seconds = Math.floor(ms / 1000);
  let minutes = Math.floor(seconds / 60);
  let hours = Math.floor(minutes / 60);

  seconds = seconds % 60;
  minutes = minutes % 60;

  return [hours, minutes, seconds].map(function(n) {
    return n.toString().padStart(2, '0');
  }).join(":")
}
Time.monthnames = function(format) {
  let full = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
  switch (format || "short") {
    case "full":
      return full
    case "short":
      return full.map(function(m) { return m.slice(0, 3) })
    case "single":
      return full.map(function(m) { return m.slice(0, 1) })
  }
}
Time.weekdays = function(format) {
  let full = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
  switch (format || "short") {
    case "full":
      return full
    case "short":
      return full.map(function(m) { return m.slice(0, 3) })
    case "single":
      return ["U", "M", "T", "W", "R", "F", "S"]
  }
}
Time.asDateStr = function(ms_since_epoch) {
  let d = Time.asData(ms_since_epoch)
  return `${d.wday}, ${d.month} ${d.date} ${d.hour}:${d.minute} ${d.mz}`
  // Fri, Feb 10 10:40am
}
Time.asData = function(ms_since_epoch) {
  ms_since_epoch = ms_since_epoch ? ms_since_epoch : Time.msSinceEpoch()
  let date = Time.at(ms_since_epoch)

  let hr = date.getHours()
  let mz = hr >= 12 ? "PM" : "AM"
  hr = hr > 12 ? hr - 12 : hr
  hr = hr == 0 ? 12 : hr

  return {
    date: date.getDate(),
    month: date.getMonth(),
    wday: date.getDay(),
    hour: hr,
    minute: date.getMinutes(),
    mz: mz,
  }
  // Fri, Feb 10 10:40am
}
Time.local = function(ms_since_epoch) {
  ms_since_epoch = ms_since_epoch ? ms_since_epoch : Time.msSinceEpoch()
  var time = Time.at(ms_since_epoch)
  var hr = time.getHours()
  var mz = hr >= 12 ? "PM" : "AM"
  hr = hr > 12 ? hr - 12 : hr
  hr = hr == 0 ? 12 : hr
  return hr + ":" + String(time.getMinutes()).padStart(2, "0") + " " + mz
}
Time.timeago = function(input) {
  const date = (input instanceof Date) ? input : new Date(input);
  if (date.getTime() == 0) { return "never" }
  const formatter = new Intl.RelativeTimeFormat('en');
  const ranges = {
    years: 3600 * 24 * 365,
    months: 3600 * 24 * 30,
    weeks: 3600 * 24 * 7,
    days: 3600 * 24,
    hours: 3600,
    minutes: 60,
    seconds: 1
  };
  const secondsElapsed = (date.getTime() - Date.now()) / 1000;
  for (let key in ranges) {
    if (ranges[key] < Math.abs(secondsElapsed)) {
      const delta = secondsElapsed / ranges[key];
      return formatter.format(Math.round(delta), key);
    }
  }
  return "just now"
}
