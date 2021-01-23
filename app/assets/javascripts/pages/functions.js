$(".ctr-functions.act-show").ready(function() {
  $(".command-form").submit(function(evt) {
    evt.preventDefault()
    $("input[type=submit]").prop("disabled", true)
    $("[name=results]").text("...")
    $("[name=results]").prop("rows", 1)

    $.ajax({
      url: $(this).attr("action"),
      type: "POST",
      data: $(this).serialize(),
      dataType: "json"
    }).always(function(data) {
      $("[name=results]").text(data.responseText)
      $("[name=results]").prop("rows", data.responseText.split(/\r\n|\r|\n/).length)
    })

    $("input[type=submit]").prop("disabled", false)
    return false
  })

})
