$("#list-item-schedule").ready(function() {
  $("#list-item-schedule input").on("focus", function() {
    this.select()
  }).on("mouseup", function(evt) {
    // Some browsers move the cursor and unselect on mouseup. Cancel that to retain the selection of the field
    evt.preventDefault()
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
