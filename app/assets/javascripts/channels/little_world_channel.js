 $('.ctr-little_worlds.act-show').ready(function() {

  App.little_world = App.cable.subscriptions.create({
    channel: "LittleWorldChannel"
  }, {
    connected: function() {
      console.log("connected");
      setTimeout(function() {
        App.little_world.logged_in()
      }, 10)
    },
    disconnected: function() {
      console.log("disconnected");
      App.little_world.logged_out()
    },
    received: function(data) {
      console.log("received", data);
      var player = Player.findPlayer(data.uuid)

      if (data.message && data.message.length > 0) {
        addMessage(player, data)
      } else {
        playerMoved(player, data)
      }
    },
    logged_in: function() {
      console.log("logged_in");
      return this.perform('logged_in', {
        uuid: currentPlayer.id
      });
    },
    logged_out: function() {
      console.log("logged_out");
      return this.perform('logged_out', {
        uuid: currentPlayer.id
      });
    }
  });

  function addMessage(player, data) {
    // Get player HTML, change text to message
    // Set Timeout to fade message away
  }

  function playerMoved(player, data) {
    if (player == undefined) {
      $(".player[data-id=" + data.uuid + "]").remove()
      littleWorld.loginPlayer(data.uuid)
    } else if (data.log_out == "true") {
      player.logOut()
    } else if (player.lastMoveTimestamp < parseInt(data.timestamp)) {
      player.setDestination([data.x, data.y])
    }
  }

})
