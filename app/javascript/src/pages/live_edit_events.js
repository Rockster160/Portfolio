$(document).ready(function() {
  if ($(".live-edit-events").length == 0) { return }

  $(".live-edit-events input, .live-edit-events textarea").each(function() {
    // Store the initial value
    $(this).data("original-value", $(this).val())
  }).blur(function() {
    let originalValue = $(this).data("original-value")
    let currentValue = $(this).val()
    if (originalValue === currentValue) { return } // Do not update if unchanged

    let params = {}
    params[$(this).attr("name")] = currentValue

    $.ajax({
      url: $(this).attr("data-update-url"),
      type: "PATCH",
      data: params
    })

    // Update the stored value
    $(this).data("original-value", currentValue)
  }).keydown(function(evt) {
    if ($(this).is("input") && evt.key == "Enter") {
      $(this).blur()
    }
  })
})
