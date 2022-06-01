import consumer from "./consumer"
import { Player } from "../pages/little_world/player.js"

export let little_world_sub
$(document).ready(function() {
  setupLittleWorldChannel = function() {
    little_world_sub = consumer.subscriptions.create({
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
        if (data.ping) { return little_world_sub.pong() }
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
})
