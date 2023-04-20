import "./reconnecting_websockets.js";

class SimpleWS {
  constructor(auth_socket, init_data) {
    let sws = this
    this.auth_socket = auth_socket
    let sock = this.auth_socket
    this.init_data = init_data

    sock.open = false
    // sock.reload = false
    sock.presend = init_data.presend

    if (!init_data.url) { return }
    this.socket = new ReconnectingWebSocket(init_data.url)

    this.socket.onopen = function() {
      sock.open = true

      if (init_data.authentication && typeof(init_data.authentication) === "function") {
        init_data.authentication.call(sws)
      }

      if (init_data.onopen && typeof(init_data.onopen) === "function") { init_data.onopen.call(sws) }
      // if (sock.reload) {
      //   // sock.cell.reload()
      //   sock.reload = false
      // }
    }

    this.socket.onclose = function() {
      sock.open = false
      // sock.reload = true
      if (init_data.onclose && typeof(init_data.onclose) === "function") { init_data.onclose.call(sws) }
    }

    this.socket.onerror = function(msg, a, b, c) {
    }

    this.socket.onmessage = function(msg) {
      if (init_data.receive && typeof(init_data.receive) === "function") {
        // if (sock.should_flash) { sock.cell.flash() }
        init_data.receive.call(sws, msg)
      }
    }
  }

  send(packet) {
    let sws = this
    let sas = this.auth_socket
    if (sas.open) {
      if (sas.presend && typeof(sas.presend) === "function") { packet = sas.presend(packet) }
      sws.socket.send(JSON.stringify(packet))
    } else {
      setTimeout(function() {
        sws.send(packet)
      }, 500)
    }
  }
  reopen() {
    let sws = this
    sws.socket = new ReconnectingWebSocket(sws.init_data.url)
  }
  close() {
    let sws = this
    sws.open = false
    sws.socket.close()
  }
}

export class AuthWS {
  constructor(subscription, callbacks) {
    let domain = location

    let ws_protocol = domain.protocol == "https:" ? "wss" : "ws", ws_open = false
    if (typeof subscription != "object") {
      subscription = { channel: subscription }
    }

    this.init_data = {
      url: ws_protocol + "://" + domain.host + "/cable?" + (domain.searchParams?.toString() || ""),
      authentication: function() {
        let ws = this
        ws.send({ subscribe: subscription })
      },
      presend: function(packet) {
        if (typeof packet != "object" || !packet.subscribe) {
          if (typeof packet == "string") {
            let new_packet = {}
            new_packet[packet] = null
            packet = new_packet
          }
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
        let cell = this
        let msg_data = JSON.parse(msg.data)
        if (msg_data.type == "ping" || !msg_data.message) { return }

        callbacks?.onmessage?.call(cell, msg_data.message)
      }
    }

    this.simple_socket = new SimpleWS(this, {...this.init_data, ...callbacks})
  }

  send(packet) {
    this.simple_socket.send(packet)
  }
}
