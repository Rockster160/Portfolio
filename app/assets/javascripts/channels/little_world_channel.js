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
    speak: function(msg) {
      return this.perform("speak", {
        uuid: currentPlayer.id,
        message: msg
      })
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
    var message_html = $("<div>", {class: "message"})
    message_html.prepend($("<span>", {class: "author"}).html(player.username + ": "))
    message_html.append(data.message)
    $(".messages-container").append(message_html)
    player.say(data.message)
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
