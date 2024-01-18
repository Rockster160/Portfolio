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
//   let laneTalk = function() {
//     let center_id = $(".league-data").attr("data-lanetalk-center-id")
//     let lanetalk_api_key = $(".league-data").attr("data-lanetalk-key")
//
//     if (!center_id || !lanetalk_api_key) {
//       if (!center_id) { console.log("Missing Center ID") }
//       if (!lanetalk_api_key) { console.log("Missing LaneTalk API Key") }
//       return
//     }
//
//     let bowler_mapping = {}
//     $(".bowler").each(function() {
//       let bowlerNum = this.getAttribute("data-bowler")
//
//       if (bowlerNum) { bowler_mapping[parseInt(bowlerNum)] = this }
//     })
//
//     let genUUID = function() {
//       return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, function(c) {
//         const r = (Math.random() * 16) | 0;
//         const v = c === "x" ? r : (r & 0x3) | 0x8;
//         return v.toString(16);
//       })
//     }
//
//     let decToPins = function(integer) {
//       if (!integer) { return [] }
//
//       let binary = integer.toString(2)
//       const zerosToAdd = Math.max(0, 10 - binary.length)
//       let binStr = "0".repeat(zerosToAdd) + binary
//       return binStr.split("").reverse().map(function(num, idx) {
//         if (num == "1") { return idx+1 }
//       }).filter(Boolean).sort()
//     }
//
//     let findCurrentLane = function(start_lane) {
//       let current_game = parseInt(params.game || 1)
//
//       return (current_game % 2 == 1) ? start_lane : findPairLane(start_lane)
//     }
//
//     let findPairLane = function(start_lane) {
//       return start_lane + (start_lane % 2 ? 1 : -1)
//     }
//
//     function calculateBowlingScore(frames) {
//       // `frames` is a flattened array of every frame.
//       // Strikes should always be followed by an empty string (non-10th) to represent no second throw
//       // Use "X", "/", "-" for strike, spare, gutter
//       // Other values should be integers (not strings of numbers)
//       let totalScore = 0
//       for (let i=0; i<frames.length; i+=2) {
//         if (i >= 20) continue
//         let frameNum = clamp(Math.floor(i/2), 0, 9) + 1
//         let frame = [frames[i], frames[i+1], frames[i+2]].slice(0, frameNum < 10 ? 2 : 3)
//         frame.forEach((toss, idx) => {
//           let tossScore = scoreFromToss(idx, frame)
//           totalScore += tossScore
//
//           if (frameNum < 10) {
//             let nextFrame = frames.slice(i+2, i+4)
//             if (toss == "X" || toss == "/") { // Double next throw
//               totalScore += scoreFromToss(0, nextFrame)
//             }
//             if (toss == "X") { // Double following next throw
//               if (nextFrame[1] == "") { // Next is strike, so jump to following
//                 nextFrame = frames.slice(i+4, i+6)
//                 totalScore += scoreFromToss(0, nextFrame)
//               } else {
//                 totalScore += scoreFromToss(1, nextFrame)
//               }
//             }
//           }
//         })
//       }
//       return totalScore
//     }
//
//     let updateEnemy = function(player) {
//       console.log("Enemy: ", player)
//       $("#enemy-scores-table").removeClass("hidden")
//       let table = $("#enemy-scores-table tbody")
//       let score = calculateBowlingScore(player.throws) // -- Won't include mid-frame
//       let enemy_vals = {
//         "enemy-num":   player.playerNumber,                // Num
//         "enemy-frame": player.scores.length,               // Frame
//         "enemy-now":   score,                              // Now
//         "enemy-hdcp":  Math.round(Math.random()*20),//player.playerHcp,                   // HDCP
//         "enemy-total": player.scoreCompletedGames + score, // Tot
//         "enemy-max":   player.maxScore,                    // Max
//       }
//       let row = table.find(`[data-player-num="${player.playerNumber}"]`)
//       if (row.length == 0) {
//         row = $("<tr>").attr("data-player-num", player.playerNumber).addClass("enemy")
//         Object.keys(enemy_vals).forEach(klass => row.append($("<td>").addClass(klass)))
//         table.append(row)
//         // reorder rows
//         let rows = table.find("tr.enemy").toArray()
//         rows.sort(function(a, b) {
//           let playerNumA = parseInt($(a).attr("data-player-num"))
//           let playerNumB = parseInt($(b).attr("data-player-num"))
//           return playerNumA - playerNumB
//         })
//         table.empty()
//         rows.forEach(item => table.append(item))
//       }
//       let total_row = table.find("#enemy-table-totals")
//       if (total_row.length == 0) {
//         total_row = $("<tr>").attr("id", "enemy-table-totals")
//         Object.keys(enemy_vals).forEach(klass => total_row.append($("<td>").addClass(`${klass}-total`)))
//         table.append(total_row)
//       }
//
//       let enemy_total = 0
//       let calc_totals = ["enemy-now", "enemy-total"]
//       for (const [klass, val] of Object.entries(enemy_vals)) {
//         row.find(`.${klass}`).text(val || 0)
//
//         if (calc_totals.indexOf(klass) < 0) { continue }
//         let sum = Array.from(table.find(`.${klass}`)).reduce((total, col) => total + parseFloat(col.textContent), 0)
//         if (klass == "enemy-now") { enemy_total = sum }
//         total_row.find(`.${klass}-total`).text(sum || 0)
//       }
//
//       let klass = "enemy-hdcp"
//       let sum = Array.from(table.find(`.${klass}`)).reduce((total, item) => total + parseFloat(item.textContent), 0)
//       total_row.find(`.${klass}-total`).text("+" + (sum + enemy_total))
//     }
//
//     let updatePlayer = function(player) {
//       player.crossLane = true
//       let current_game = parseInt(params.game || 1)
//       if (player.game != current_game) { return }
//
//       let lane_input = parseInt($(".lane-input").val())
//       if (!lane_input) { return }
//
//       let current_lane = player.crossLane ? findCurrentLane(lane_input) : lane_input
//
//       if (player.lane != current_lane) {
//         let enemy = player.crossLane && current_lane == findPairLane(player.lane)
//         return enemy ? updateEnemy(player) : null
//       }
//       let bowler = bowler_mapping[player.playerNumber]
//       if (!bowler) { return }
//       console.log(player);
//
//       player.throws.forEach(function(toss_str, idx) {
//         let toss_value = toss_str
//         let throw_frame = Math.floor(idx / 2) + 1
//         let throw_idx = idx % 2
//         if (idx == 20) {
//           throw_frame = 10
//           throw_idx = 2
//         }
//         if (toss_value == "X") {
//           toss_value = 10
//         } else if (toss_value == "/") {
//           toss_value = 10 - (parseInt(player.throws[idx-1]) || 0)
//         }
//         let standing_pins = decToPins(player.pins[idx])
//
//         let frame = bowler.querySelector(`.bowling-cell[data-frame="${throw_frame}"]`)
//         let shot = frame.querySelector(`.shot[data-shot-idx="${throw_idx}"]`)
//         if (pinTimer && shot.hasClass(".current")) { return } // Do not update the current frame if currently touching
//
//         let throw_slot = frame.querySelector(`.fallen-pins[data-shot-idx="${throw_idx}"]`)
//         if (toss_value == "") {
//           throw_slot.value = null
//           shot.value = null
//           shot.setAttribute("data-score", null)
//         } else {
//           throw_slot.value = `[${standing_pins.join(",")}]`
//           shot.value = toss_str
//           shot.setAttribute("data-score", toss_value)
//         }
//
//         applyFrameModifiers($(shot))
//         recalculateFrame($(shot))
//       })
//
//       if (pinTimer) { return }
//       calcScores()
//       moveToNextFrame()
//     }
//
//     let connectLaneTalkWs = function() {
//       let socket = new WebSocket("wss://ws.lanetalk.com/ws")
//       let send = function(json) { socket.send(JSON.stringify(json)) }
//
//       socket.addEventListener("open", function(event) {
//         send({
//           id: genUUID(),
//           method: 0,
//           params: { api_key: lanetalk_api_key }
//         })
//       })
//
//       socket.addEventListener("message", function(event) {
//         if (!useLaneTalk) { return }
//         let json = JSON.parse(event.data)
//         let result = json.result || {}
//         if (result.result?.client) {
//           send({
//             id: genUUID(),
//             method: 1,
//             params: { channel: `LiveScores:${center_id}` }
//           })
//         } else if (Object.keys(result).length > 0) {
//           if (result.type == 5) {
//             updatePlayer(result.data)
//           } else {
//             json.result.publications[0].data.lanes.forEach(function(player) {
//               updatePlayer(player)
//             })
//           }
//         }
//       })
//
//       socket.addEventListener("close", function(event) {
//         setTimeout(function() {
//           connectLaneTalkWs()
//         }, 5000)
//       })
//     }
//     connectLaneTalkWs()
//   }
//
// })
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
