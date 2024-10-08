export function Time() {}
Time.now = function() { return new Date() }
Time.msSinceEpoch = function() { return Time.now().getTime() }

Time.seconds = Time.second = function(n) { return n === 0 ? 0 : (n || 1) * 1000 }
Time.minutes = Time.minute = function(n) { return n === 0 ? 0 : Time.seconds((n || 1) * 60) }
Time.hours = Time.hour = function(n) { return n === 0 ? 0 : Time.minutes((n || 1) * 60) }
Time.days = Time.day = function(n) { return n === 0 ? 0 : Time.hours((n || 1) * 24) }
Time.weeks = Time.week = function(n) { return n === 0 ? 0 : Time.days((n || 1) * 7) }
Time.months = Time.month = function(n) { return n === 0 ? 0 : Time.days((n || 1) * 30) }
Time.years = Time.year = function(n) { return n === 0 ? 0 : Time.days((n || 1) * 365) }

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
    return n.toString().padStart(2, "0");
  }).join(":")
  // 03:43
}
Time.humanDuration = function(left, sigFigs = 2) {
  left = Math.floor(left);
  if (!left || left < Time.second()) { return "<1s" }

  const timeLengths = {
    w: Time.week(),
    d: Time.day(),
    h: Time.hour(),
    m: Time.minute(),
    s: Time.second()
  };

  let durations = [];
  for (const [time, length] of Object.entries(timeLengths)) {
    if (length > left || durations.length >= sigFigs) { continue };

    const count = Math.floor(left / length);
    left -= count * length;

    durations.push(`${count}${time}`);
  }

  return durations.join(" ");
}
Time.monthnames = function(format) {
  let full = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
  switch (format || "full") {
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
  switch (format || "full") {
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
  return `${d.wday}, ${d.month} ${d.date} ${d.hour}:${d.minute}${d.mz}`
  // Fri, Feb 17 9:02am
}
Time.asData = function(ms_since_epoch, format) {
  format = format || "short"
  ms_since_epoch = ms_since_epoch || Time.msSinceEpoch()
  let date = Time.at(ms_since_epoch)

  let hr = date.getHours()
  let mz = hr >= 12 ? "pm" : "am"
  hr = hr > 12 ? hr - 12 : hr
  hr = hr == 0 ? 12 : hr

  return {
    date:   date.getDate(),                             // 17
    month:  Time.monthnames(format)[date.getMonth()],   // "Feb"
    wday:   Time.weekdays(format)[date.getDay()],       // "Fri"
    hour:   hr,                                         // 9
    minute: String(date.getMinutes()).padStart(2, "0"), // "02"
    mz:     mz,                                         // "am"
  }
}
Time.local = function(ms_since_epoch) {
  ms_since_epoch = ms_since_epoch || Time.msSinceEpoch()
  var time = Time.at(ms_since_epoch)
  var hr = time.getHours()
  var mz = hr >= 12 ? "pm" : "am"
  hr = hr > 12 ? hr - 12 : hr
  hr = hr == 0 ? 12 : hr
  return hr + ":" + String(time.getMinutes()).padStart(2, "0") + mz
  // 8:03 am
}
Time.timeago = function(input, format) {
  const date = Time.at(input);
  if (date.getTime() == 0) { return "never" }
  const formatter = new Intl.RelativeTimeFormat('en');
  const msElapsed = date.getTime() - Date.now();
  if (format == "short") {
    return Time.humanDuration(Math.abs(msElapsed));
  }
  for (const range of ["years", "months", "weeks", "days", "hours", "minutes", "seconds"]) {
    let rangeDuration = Time[range]()
    if (rangeDuration < Math.abs(msElapsed)) {
      const delta = msElapsed / rangeDuration;
      return formatter.format(Math.round(delta), range);
    }
  }
  return "just now";
  // 17 hours ago
}
