 setupLittleWorldChannel = function() {
  App.little_world = App.cable.subscriptions.create({
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
      console.log(data);
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
    }
  });
}
