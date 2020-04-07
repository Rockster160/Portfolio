$(document).ready(function() {
  var clearRlcForm = function() {
    $(".rlc-form input, .rlc-form textarea").val("")
    $(".rlc-form input[type=checkbox]").prop("checked", false)
    $(".edit-form").addClass("hidden")
  }

  $(".clear-btn").click(function() {
    clearRlcForm()
  })

  $(".rlc-form").submit(function(evt) {
    evt.preventDefault()

    $.ajax({
      type: "PATCH",
      url: $(this).attr("href"),
      data: $(this).serialize()
    }).done(function(data) {
      rlc_map.add_points([data])

      clearRlcForm()
    })
  })
})
