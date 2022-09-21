console.log("Start");
$(document).ready(function() {
  console.log("Ready");
  if ($(".live-edit-events").length == 0) { return }
  console.log("Found");

  $(".live-edit-events input").blur(function() {
    console.log("Blur");
    let params = {}
    params[$(this).attr("name")] = $(this).val()

    $.ajax({
      url: $(this).attr("data-update-url"),
      type: "PATCH",
      data: params
    })
  })
})
