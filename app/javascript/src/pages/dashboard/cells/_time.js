export function Time() {}
Time.now = function() { return new Date() }
Time.msSinceEpoch = function() { return Time.now().getTime() }
Time.seconds = Time.second = function(n) { return (n || 1) * 1000 }
Time.minutes = Time.minute = function(n) { return Time.seconds((n || 1) * 60) }
Time.hours = Time.hour = function(n) { return Time.minutes((n || 1) * 60) }
Time.days = Time.day = function(n) { return Time.hours((n || 1) * 24) }
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
Time.duration = function(ms) {
  return (new Date(ms)).toISOString().substr(11, 8)
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
