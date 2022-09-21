$(document).ready(function() {
  if ($(".live-edit-events").length == 0) { return }

  $(".live-edit-events input").blur(function() {
    let params = {}
    params[$(this).attr("name")] = $(this).val()

    $.ajax({
      url: $(this).attr("data-update-url"),
      type: "PATCH",
      data: params
    })
  }).keydown(function(evt) {
    if (evt.key == "Enter") {
      $(this).blur()
    }
  })
})
