import consumer from "./consumer"

$(document).ready(function() {
  if ($(".ctr-nfcs.act-show").length == 0) { return }

  consumer.subscriptions.create({
    channel: "NfcChannel"
  }, {
    connected: function() {
      console.log("connected")
    },
    disconnected: function() {
      console.log("disconnected")
    },
    received: function(data) {
      console.log("received")
      $(".nfc-code").text(data.message)
    }
  })

})
