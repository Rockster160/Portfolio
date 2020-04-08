$(document).ready(function() {
  var rlc_map = RLCraftSVG.getMap()

  $(".clear-btn").click(function() {
    clearRlcForm()
  })

  $("[data-rlc-show]").change(function() {
    var type = $(this).attr("data-rlc-show")

    if (this.checked) {
      $("circle[rlc-color=" + type + "]").removeClass("hidden")
    } else {
      $("circle[rlc-color=" + type + "]").addClass("hidden")
    }
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
