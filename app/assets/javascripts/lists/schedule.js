$("#list-item-schedule").ready(function() {

  var ordinalize = function(numstr) {
    var num = parseInt(numstr.toString().substr(-1))
    if (num == 1) { return "st" }
    else if (num == 2) { return "nd" }
    else if (num == 3) { return "rd" }
    else { return "th" }
  }

  $("#list-item-schedule input").on("focus", function() {
    this.select()
  }).on("mouseup touchend", function(evt) {
    // Some browsers move the cursor and unselect on mouseup. Cancel that to retain the selection of the field
    evt.preventDefault()
  })

  $("#repeat-interval").on("blur", function() {
    if ($(this).val().length == 0) { $(this).val("1") }
    // $(".ordinal-unit").text(ordinalize($(this).val()))
  }).on("blur paste keyup input change", function() {
    $(this).val($(this).val().replace(/[^\d]/, ""))
  })

})
