import { Time } from "./_time"

(function() {
  Cell.register({
    title: "Ping",
    wrap: true,
    socket: Server.socket("PingChannel", function(msg) {
      let str = JSON.stringify(msg)

      if (str.trim().replace(/\{|\}/ig, "").length > 0) {
        let pings = localStorage.getItem("ping_data")?.split("\n")?.slice(0, 20) || []
        pings.unshift("[" + Time.local() + "] " + str)
        pings = pings.join("\n")
        localStorage.setItem("ping_data", pings)
        this.text(pings)
      }

      this.flash()
    }),
    reloader: function() {
      this.text(localStorage.getItem("ping_data"))
    },
    command: function(msg) {
      console.log(msg);
      let [channel, ...data] = msg.split(" ")
      this.ws.send({ channel: channel, data: data.join(" ") })
    },
    commands: {
      clear: function() {
        localStorage.setItem("ping_data", "")
        this.text("")
      },
      ping: function() {
        this.ws.send({ action: "message", ping: "pong" })
      }
    },
  })
})()
