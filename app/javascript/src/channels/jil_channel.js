import consumer from "./consumer"

$(document).ready(function() {
  if ($(".ctr-jarvis_tasks.act-new, .ctr-jarvis_tasks.act-edit").length == 0) { return }

  consumer.subscriptions.create(
    "JilChannel",
    {
      received: function(data) {
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
    }
  )
})
