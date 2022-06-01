$('.ctr-log_trackers.act-index').ready(function() {

  App.logger = App.cable.subscriptions.create({
    channel: "LoggerChannel"
  }, {
    connected: function() {
      console.log("connected");
    },
    disconnected: function() {
      console.log("disconnected");
    },
    received: function(data) {
      console.log("received");
      $('.log-tracker-table .tbody').prepend(data.message);
    }
  });

})
