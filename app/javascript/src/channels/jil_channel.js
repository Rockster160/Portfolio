import consumer from "./consumer"

$(document).ready(function() {
  if ($(".ctr-jarvis_tasks.act-new, .ctr-jarvis_tasks.act-edit").length == 0) { return }
  if (!window.location.pathname.match(/tasks\/([\d\w]+)/)) { return }

  consumer.subscriptions.create({
    channel: "JilChannel",
    id: window.location.pathname.match(/tasks\/([\d\w]+)/)[1],
  },{
    received: function(data) {
      console.log(data);
      $("[token]").removeClass("task-running")
      $(".jil-console code").text(data.output)
      if (data.token) {
        let current = $(`[token="${data.token}"]`)
        current.addClass("task-running").addClass("task-starting")

        setTimeout(function() {
          current.removeClass("task-starting")
        }, 200) // Corresponds to 0.2s transition
      }
    }
  })
})
