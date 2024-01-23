$(document).ready(function() {
  if ($(".ctr-bowling_leagues.act-tms").length == 0) { return }
  var calcAvgChange = function(bowler, new_val) {
    new_val = parseInt(new_val)
    if (isNaN(new_val)) { return "" }
    var games = parseInt(bowler.attr("data-gms"))
    var pins = parseInt(bowler.attr("data-pins"))
    var series = parseInt(bowler.attr("data-gms-per-series"))
    var old_avg = pins / games
    if (new_val < old_avg * 2) { new_val = new_val * 3 }

    var new_pins = pins + new_val
    var new_games = games + series

    return Math.floor(new_pins / new_games)
  }

  $(".quick-avg-check").keyup(function() {
    var bowler = $(this).parents(".league-bowler")
    var newAvg = calcAvgChange(bowler, $(this).val())

    bowler.children(".quick-avg-out").text(newAvg)
  })
})

$(document).ready(function() {
  if ($(".ctr-bowling_leagues.act-new, .ctr-bowling_leagues.act-edit").length == 0) { return }
  $(".league-roster").sortable({
    handle: ".bowler-handle",
    update: function(evt, ui) { updateRoster() }
  })

  $("#bowling_league_team_size").change(function() { updateRoster() })

  updateRoster = function() {
    var roster = $(".league-roster")
    roster.find(".bowler-form:not(.hidden)").each(function(idx) {
      $(this).find(".position").val(idx + 1)
    })

    var team_size = parseInt($("#bowling_league_team_size").val()) || 1
    $(".in-roster").remove()
    $(".bowler-form:not(.hidden)").each(function(idx) {
      if (idx + 1 > team_size) { return }

      var star = $("<i>", { class: "fa fa-star in-roster" })
      $(this).append(star)
    })
  }
  updateRoster()

  $(document).on("click", ".remove-bowler", function(evt) {
    var bowler = $(this).parents(".bowler-form")

    if (bowler.find(".bowler-id").val() == "") {
      bowler.remove()
    } else {
      bowler.find(".should-destroy").val(true)
      bowler.addClass("hidden")
    }

    updateRoster()
  })

  var template = document.querySelector("#bowler-template")
  $(".add-bowler").click(function() {
    var clone = template.content.cloneNode(true)

    $(".league-roster").append(clone)
    updateRoster()
  })
})
