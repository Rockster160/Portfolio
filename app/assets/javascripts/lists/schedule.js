$("#list-item-schedule").ready(function() {
  var hold_val

  $("#list-item-schedule input").on("focus", function() {
    hold_val = $(this).val()
    $(this).val("")
  }).blur(function() {
    if ($(this).val().replace(/\s/g, '').length == 0) { $(this).val(hold_val) }
    hold_val = undefined
  })

  $("#repeat-interval").on("blur", function() {
    if ($(this).val().length == 0) { $(this).val("1") }
  }).on("blur paste keyup input change", function() {
    $(this).val($(this).val().replace(/[^\d]/, ""))
  })

  $("#schedule-form").submit(function() {
    hideModal()
  })
})
