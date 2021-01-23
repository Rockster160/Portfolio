$(".ctr-functions.act-show").ready(function() {
  $(".command-form").submit(function(evt) {
    evt.preventDefault()
    $("input[type=submit]").prop("disabled", true)
    $("[name=results]").text("...")

    $.ajax({
      url: $(this).attr("action"),
      type: "POST",
      data: $(this).serialize(),
      dataType: "json"
    }).always(function(data) {
      $("[name=results]").text(data.responseText)
    })

    $("input[type=submit]").prop("disabled", false)
    return false
  })

})
