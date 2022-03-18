var demo = !true
var local_data_timer, local_reminders_cell, local_calendar_cell

// var cell = Cell.init({
//   title: "",
//   text: "",
//   commands: {},
//   interval: Time.minute(),
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
    authentication: function(ws) {
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
    receive: function(cell, msg) {
      var msg_data = JSON.parse(msg.data)
      if (msg_data.type == "ping" || !msg_data.message) { return }

      receive(cell, msg_data.message)
    }
  }
}

// App.localData.request()
App.localData = App.cable.subscriptions.create({
  channel: "LocalDataChannel"
}, {
  connected: function() {
    clearTimeout(local_data_timer)
    local_data_timer = setTimeout(function() { App.localData.request() }, 50)
  },
  received: function(data) {
    if (local_calendar_cell) {
      local_calendar_cell.commands.render(local_calendar_cell, data.calendar)
    }
    if (local_reminders_cell) {
      local_reminders_cell.commands.render(local_reminders_cell, data.reminders)
    }
  },
  request: function() {
    return this.perform("request")
  }
})
