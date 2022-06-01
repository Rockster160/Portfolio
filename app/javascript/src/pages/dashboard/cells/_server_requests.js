import consumer from "./../../../channels/consumer"
import { dash_colors } from "../vars"

var demo = !true

// var cell = Cell.register({
//   title: "",
//   text: "",
//   commands: {},
//   refreshInterval: Time.minute(),
//   reloader: function(cell) {},
//   command: function(text, cell) {},
//   socket: {
//     url: "",
//     subscription: {
//       channel: "",
//       channel_id: "",
//     },
//     receive: function(cell, msg) {}
//   },
// })

Server = function() {}
Server.request = function(url, type, data) {
  return $.ajax({
    url: url,
    data: data || {},
    dataType: "text",
    type: type || "GET",
  })
  // Catch fails and show a useful error
}
Server.post   = function(url, data) { return Server.request(url, "POST",  data) }
Server.patch  = function(url, data) { return Server.request(url, "PATCH", data) }
Server.get    = function(url, data) { return Server.request(url, "GET",   data) }
Server.socket = function(subscription, receive) {
  var receive = receive
  var ws_protocol = location.protocol == "https:" ? "wss" : "ws", ws_open = false
  if (typeof subscription != "object") {
    subscription = { channel: subscription }
  }

  return {
    url: ws_protocol + "://" + location.host + "/cable",
    authentication: function() {
      var ws = this
      ws.send({ subscribe: subscription })
    },
    presend: function(packet) {
      if (typeof packet != "object" || !packet.subscribe) {
        packet = {
          command: "message",
          identifier: JSON.stringify(subscription),
          data: JSON.stringify(packet)
        }
      } else {
        packet = {
          command: "subscribe",
          identifier: JSON.stringify(packet.subscribe)
        }
      }

      return packet
    },
    receive: function(msg) {
      var cell = this
      var msg_data = JSON.parse(msg.data)
      if (msg_data.type == "ping" || !msg_data.message) { return }

      receive.call(cell, msg_data.message)
    }
  }
}

// window.localDataChannel.request()
window.localDataChannel = consumer.subscriptions.create({
  channel: "LocalDataChannel"
}, {
  connected: function() {
    clearTimeout(window.local_data_timer)
    window.local_data_timer = setTimeout(function() { window.localDataChannel.request() }, 50)
  },
  received: function(data) {
    if (window.local_calendar_cell) {
      window.local_calendar_cell.commands.render.call(window.local_calendar_cell, data.calendar)
    }
    if (window.local_reminders_cell) {
      window.local_reminders_cell.commands.render.call(window.local_reminders_cell, data.reminders)
    }
  },
  request: function() {
    return this.perform("request")
  }
})
