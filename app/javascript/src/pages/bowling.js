// $(document).ready(function() {
//   if ($(".ctr-bowling_games.act-new, .ctr-bowling_games.act-edit").length == 0) { return }
//   let currentScorePush = null
//   var inProgress = false
//   var should_check_stats = true
//
//   $(document).on("modal.shown", function() {
//     $(".shot.current").removeClass("current")
//   }).on("modal.hidden", function() {
//     gotoNextFrame()
//   })
//
//
//   }).on("click", ".edit-bowler-name", function(evt) {
//     evt.preventDefault()
//     evt.stopPropagation()
//     var name = prompt("Enter bowler name")
//     if (name.length < 1) { return }
//
//     var bowler = $(this).parents(".bowler")
//
//     bowler.find(".name .display-name").html(name)
//     bowler.find(".bowler-options-name").html(name)
//     bowler.find(".bowler-name-field").val(name)
//     bowler.find(".bowler-sub-btn").attr("data-bowler-name", name)
//   })
//
//   $(document).on("click", ".bowling-navigation .nav-buttons", function(evt) {
//     var btn = $(this)
//     var input = $(".bowling-input")
//     var left = input.hasClass("left")
//     var right = input.hasClass("right")
//
//     if (btn.hasClass("left")) {
//       if (left) {
//         input.removeClass("left").addClass("right")
//       } else if (right) {
//         input.removeClass("right")
//       } else {
//         input.addClass("left")
//       }
//     } else if (btn.hasClass("right")) {
//       if (right) {
//         input.removeClass("right").addClass("left")
//       } else if (left) {
//         input.removeClass("left")
//       } else {
//         input.addClass("right")
//       }
//     }
//   })
//
//   $(".bowling-input .numpad-key.entry").click(function() {
//     $(".pin-wrapper").removeClass("fallen").removeClass("fallen-before")
//     $(".shot.current").parents(".frame").find(".fallen-pins").val("")
//     addScore($(this).text())
//   })
//
//
//   swap = function($ele1, $ele2) {
//     var temp = $("<div>")
//
//     $ele1.before(temp)
//     $ele2.before($ele1)
//     temp.before($ele2).remove()
//   }
//
// // {
// //   "result": {
// //     "channel": "LiveScores:xxx-xxx-xxx-xxx",
// //     "type": 5,
// //     "data": {
// //       "bowlingCenterUuid": "xxx-xxx-xxx-xxx",
// //       "lane": 22,
// //       "game": 2,
// //       "crossLane": false,
// //       "playerName": "Lisa Taylor",
// //       "playerNumber": 2,
// //       "playerHcp": 83,
// //       "teamName": "Flying Balls",
// //       "teamHcp": 193,
// //       "scoreCompletedGames": 167,
// //       "throws": [1, 3, 7, "/", 9, "-", 7, "-"],
// //       "pins": [511, 311, 52, 0, 512, 512, 11, 11],
// //       "scores": [4, 23, 32, 39],
// //       "speed": [3023, 3543, 3082, 3082, 3152, 3152, 3200, 2729],
// //       "belongsTo": null,
// //       "received": 1701995577,
// //       "maxScore": 210
// //     }
// //   }
// // }






























// ========================= Other Pages



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
