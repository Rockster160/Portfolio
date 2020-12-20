$(".ctr-nfcs.act-show").ready(function() {

  App.logger = App.cable.subscriptions.create({
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
