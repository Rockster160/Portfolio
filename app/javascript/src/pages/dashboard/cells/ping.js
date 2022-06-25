(function() {
  Cell.register({
    title: "Ping",
    wrap: true,
    socket: Server.socket("PingChannel", function(msg) {
      let str = msg.ping ? JSON.stringify(msg.ping) : ""

      if (str.trim().replace(/\{|\}/ig, "").length > 0) {
        let pings = localStorage.getItem("ping_data")?.split("\n")?.slice(0, 20) || []
        pings.unshift(str)
        pings = pings.join("\n")
        localStorage.setItem("ping_data", pings)
        this.text(pings)
      }

      this.flash()
    }),
    reloader: function() {
      this.text(localStorage.getItem("ping_data"))
    },
  })
})()
