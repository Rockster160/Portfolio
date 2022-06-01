import consumer from "./consumer"

$(".ctr-nfcs.act-show").ready(function() {

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
