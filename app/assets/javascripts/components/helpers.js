$(document).ready(function() {

  $(document).on("click", "[data-clickit]", function() {
    $($(this).attr("data-clickit")).click()
  })

})
