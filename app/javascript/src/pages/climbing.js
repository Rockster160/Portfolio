$(document).ready(function() {
  if ($(".ctr-climbs").length == 0) { return }

  $(".numpad-key").click(function() {
    let input = $(this).text()
    if (input == "<<") {
      $(".output span").last().remove()
    } else {
      let span = $("<span>").attr("score", $(this).attr("score")).text(input)
      $(".output").append(span)
    }
    const output = document.querySelector(".output")
    output.scrollLeft = output.scrollWidth - output.clientWidth

    let scores = $(".output span").toArray().map(function(span) { return Number($(span).attr("score")) })

    $("#climb_data").val(scores.join(" "))
    $(".full-score").text(
      scores.reduce(function(sum, score) { return sum + score }, 0)
    )
  })
})
