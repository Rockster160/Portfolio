$(document).ready(function() {
  if ($(".ctr-climbs.act-edit").length == 0) { return }
  // TODO: Store by route, /new, /1, etc...

  let saveClick = false

  let getStored = function() {
    return localStorage.getItem("climb")?.split(" ")
  }

  let setStored = function(new_store) {
    localStorage.setItem("climb", new_store)
  }

  let clearStored = function(new_store) {
    localStorage.removeItem("climb")
  }

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

    let climb_spans = $(".output span").toArray()

    let climbs = climb_spans.map(function(span) { return Number($(span).text()) })
    let scores = climb_spans.map(function(span) { return Number($(span).attr("score")) })

    if (saveClick) { setStored(climbs.join(" ")) }
    $("#climb_data").val(climbs.join(" "))
    $(".full-score").text(scores.sum())
  })

  // Hacky, just click the button for each rather than having to go look up the scores and such.
  let prior_climbs = getStored()
  if (prior_climbs) {
    prior_climbs.forEach(function(num) {
      $(`.numpad-key:contains("${num}")`).filter(function() {
        return $(this).text() == num
      }).click()
    })
    saveClick = true
  }

  $("form").submit(function() {
    clearStored()
  })
})
