import consumer from "./consumer"

$(document).ready(function() {
  if ($(".ctr-log_trackers.act-index").length == 0) { return }

  consumer.subscriptions.create({
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
