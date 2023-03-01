$(document).ready(function() {

  $(document).on("click", "[data-clickit]", function() {
    $($(this).attr("data-clickit")).click()
  })

  $(document).on("touchend", ".no-zoom", function(evt) {
    evt.preventDefault();
    // This is a hack that prevents default browsers from zooming in when
    //   double-clicking elements when preventing the default behavior of a click,
    //   but then calling the normal click action on the element to trigger other
    //   events or click actions.
    $(this).click();
    return false;
  })

  $("[data-watches-selector]").each(function() {
    var watcher = $(this), watching = $(watcher.attr("data-watches-selector"))

    var reactToChange = function() {
      if (watching.val() == watcher.attr("data-watches-value")) {
        watcher.removeClass("hidden")
        watcher.find("input, textarea, button").prop("disabled", false).prop("readonly", false).removeAttr("form")
      } else if (watcher.attr("data-watches-radio") !== undefined && $(watcher.attr("data-watches-selector") + ":checked").val() == watcher.attr("data-watches-radio")) {
        watcher.removeClass("hidden")
        watcher.find("input, textarea, button").prop("disabled", false).prop("readonly", false).removeAttr("form")
      } else {
        watcher.addClass("hidden")
        watcher.find("input, textarea, button").prop("disabled", true).prop("readonly", true).attr("form", "none")
      }
    }

    reactToChange()
    watching.on("change", reactToChange)
  })

})
