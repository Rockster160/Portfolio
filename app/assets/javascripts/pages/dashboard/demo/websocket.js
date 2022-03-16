$(".ctr-dashboard").ready(function() {
  var currentTime = function() {
    var now = new Date()
    var hr = now.getHours()
    var mz = hr >= 12 ? "PM" : "AM"
    hr = hr > 12 ? hr - 12 : hr
    return hr + ":" + String(now.getMinutes()).padStart(2, "0") + ":" + String(now.getSeconds()).padStart(2, "0") + " " + mz
  }

  Cell.init({
    title: "Websockets",
    text: "Connecting...",
    socket: {
      url: "wss://swift-ringed-jackal.glitch.me",
      receive: function(cell, msg) {
        var lines = cell.lines()
        lines.unshift(Text.justify(msg.data, currentTime()))
        cell.lines(lines.slice(0, 10))
      }
    },
  })
})
