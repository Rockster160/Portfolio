import consumer from "./consumer"

 setupLittleWorldChannel = function() {
  consumer.subscriptions.create({
    channel: "LittleWorldChannel",
    avatar_uuid: currentPlayer.id
  }, {
    connected: function() {
      littleWorld.connected()
    },
    disconnected: function() {
      littleWorld.disconnected()
    },
    received: function(data) {
      if (data.ping) { return App.little_world.pong() }
      var player = Player.findPlayer(data.uuid)

      if (player == undefined) {
        $(".player[data-id=" + data.uuid + "]").remove()
        return littleWorld.loginPlayer(data)
      }

      player.reactToData(data)
    },
    speak: function(msg) {
      return this.perform("speak", {
        uuid: currentPlayer.id,
        message: msg,
        timestamp: nowStamp()
      })
    },
    ping: function() {
      return this.perform("ping")
    },
    pong: function() {
      return this.perform("pong", {
        uuid: currentPlayer.id
      })
    }
  });
}
