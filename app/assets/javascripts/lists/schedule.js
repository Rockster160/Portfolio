Date.prototype.stdTimezoneOffset = function () {
  var jan = new Date(this.getFullYear(), 0, 1);
  var jul = new Date(this.getFullYear(), 6, 1);
  return Math.max(jan.getTimezoneOffset(), jul.getTimezoneOffset());
}

Date.prototype.isDstObserved = function () {
  return this.getTimezoneOffset() < this.stdTimezoneOffset();
}

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

  if ($("#hour").val() == "") {
    var hour = (new Date()).getHours()
    var meridian = "AM"
    var timezone
    if (hour > 12) {
      hour -= 12
      meridian = "PM"
    }
    $("#hour").val(hour)
    $("#meridian").prop("checked", meridian == "PM")
  }
  $("#timezone").val((new Date()).getTimezoneOffset() / -0.6) // 0.6 gets us the "600" rather than +6, negative because this returns the differece, not the offset.

})
