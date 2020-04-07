$(document).ready(function() {
  var rlc_map = RLCraftSVG.getMap()

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
      if (data.removed) {
        rlc_map.remove_points([data])
      } else {
        rlc_map.add_points([data])
      }

      clearRlcForm()
    })
  })

  var clearRlcForm = function() {
    $(".rlc-form input, .rlc-form textarea").val("")
    $(".rlc-form input[type=checkbox]").prop("checked", false)
    $(".edit-form").addClass("hidden")
  }
})
