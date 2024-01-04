// $(document).ready(function() {
//   if ($(".ctr-bowling_leagues.act-tms").length == 0) { return }
//   var calcAvgChange = function(bowler, new_val) {
//     new_val = parseInt(new_val)
//     if (isNaN(new_val)) { return "" }
//     var games = parseInt(bowler.attr("data-gms"))
//     var pins = parseInt(bowler.attr("data-pins"))
//     var series = parseInt(bowler.attr("data-gms-per-series"))
//     var old_avg = pins / games
//     if (new_val < old_avg * 2) { new_val = new_val * 3 }
//
//     var new_pins = pins + new_val
//     var new_games = games + series
//
//     return Math.floor(new_pins / new_games)
//   }
//
//   $(".quick-avg-check").keyup(function() {
//     var bowler = $(this).parents(".league-bowler")
//     var newAvg = calcAvgChange(bowler, $(this).val())
//
//     bowler.children(".quick-avg-out").text(newAvg)
//   })
// })
// $(document).ready(function() {
//   if ($(".ctr-bowling_leagues.act-new, .ctr-bowling_leagues.act-edit").length == 0) { return }
//   $(".league-roster").sortable({
//     handle: ".bowler-handle",
//     update: function(evt, ui) { updateRoster() }
//   })
//
//   $("#bowling_league_team_size").change(function() { updateRoster() })
//
//   updateRoster = function() {
//     var roster = $(".league-roster")
//     roster.find(".bowler-form:not(.hidden)").each(function(idx) {
//       $(this).find(".position").val(idx + 1)
//     })
//
//     var team_size = parseInt($("#bowling_league_team_size").val()) || 1
//     $(".in-roster").remove()
//     $(".bowler-form:not(.hidden)").each(function(idx) {
//       if (idx + 1 > team_size) { return }
//
//       var star = $("<i>", { class: "fa fa-star in-roster" })
//       $(this).append(star)
//     })
//   }
//   updateRoster()
//
//   $(document).on("click", ".remove-bowler", function(evt) {
//     var bowler = $(this).parents(".bowler-form")
//
//     if (bowler.find(".bowler-id").val() == "") {
//       bowler.remove()
//     } else {
//       bowler.find(".should-destroy").val(true)
//       bowler.addClass("hidden")
//     }
//
//     updateRoster()
//   })
//
//   var template = document.querySelector("#bowler-template")
//   $(".add-bowler").click(function() {
//     var clone = template.content.cloneNode(true)
//
//     $(".league-roster").append(clone)
//     updateRoster()
//   })
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
// $(document).ready(function() {
//   if ($(".ctr-bowling_games.act-new, .ctr-bowling_games.act-edit").length == 0) { return }
//   let currentScorePush = null
//   var inProgress = false
//   var should_check_stats = true
//
//   resetBowlerOrder = function() {
//     $(".bowler").each(function(idx) {
//       $(this).attr("data-bowler", idx + 1)
//       $(this).find(".game-position").val(idx + 1)
//     })
//   }
//
//   window.onbeforeunload = function(evt) {
//     if (!inProgress) {
//       return undefined
//     }
//
//     return "onbeforeunload"
//   }
//
//   $(document).on("modal.shown", function() {
//     $(".shot.current").removeClass("current")
//   }).on("modal.hidden", function() {
//     gotoNextFrame()
//   })
//
//   $(document).on("submit", ".add-new-bowler", function(evt) {
//     evt.preventDefault()
//
//     var form = $(this)
//     var url = form.attr("action")
//
//     $.post(url, form.serialize()).done(function(data, status, xhr) {
//       var in_bowler = $(data.html)
//       var out_bowler_id = $(".sub-out-name").attr("data-bowler-id")
//       var out_bowler = $(".bowler[data-bowler-id=" + out_bowler_id + "]")
//
//       $("#bowler_name").val("")
//       $("#bowler_total_games_offset").val("")
//       $("#bowler_total_pins_offset").val("")
//
//       $($("#game-sub-list").get(0).content).append(in_bowler)
//       hideModal("#bowler-sub-list")
//       if (out_bowler.length > 0) {
//         swap(in_bowler, out_bowler)
//       } else {
//         $(in_bowler).insertBefore(".bowler-placeholder")
//       }
//       resetEdits()
//       resetBowlerOrder()
//       calcScores()
//     })
//   })
//
//   $(document).on("click", ".bowler-select", function(evt) {
//     var out_bowler_id = $(".sub-out-name").attr("data-bowler-id")
//     var in_bowler_id = $(this).attr("data-bowler-id")
//
//     var in_bowler = $($("#game-sub-list").get(0).content).find(".bowler[data-bowler-id=" + in_bowler_id + "]")
//     var out_bowler = $(".bowler[data-bowler-id=" + out_bowler_id + "]")
//
//     hideModal("#bowler-sub-list")
//     if (out_bowler.length > 0) {
//       swap(in_bowler, out_bowler)
//     } else {
//       $(in_bowler).insertBefore(".bowler-placeholder")
//     }
//     resetEdits()
//     resetBowlerOrder()
//     calcScores()
//   })
//
//   $(document).on("click", ".bowler-sub-btn", function(evt) {
//     var name = $(this).attr("data-bowler-name")
//     $(".sub-out-name").text(name).attr("data-bowler-id", $(this).attr("data-bowler-id"))
//     $(".sub-message").removeClass("hidden")
//
//     $(".bowler-select").removeClass("hidden")
//     $(".bowler").each(function() {
//       $(".bowler-select[data-bowler-id=" + $(this).attr("data-bowler-id") + "]").addClass("hidden")
//     })
//
//     showModal("#bowler-sub-list")
//   }).on("click", ".new-bowler", function(evt) {
//     evt.preventDefault()
//     evt.stopPropagation()
//     $(".sub-message").addClass("hidden")
//     $(".bowler-select").removeClass("hidden")
//     $(".bowler").each(function() {
//       if (!$(this).attr("data-bowler-id")) { return }
//       $(".bowler-select[data-bowler-id=" + $(this).attr("data-bowler-id") + "]").addClass("hidden")
//     })
//
//     showModal("#bowler-sub-list")
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
//   $(document).on("change", ".absent-checkbox", function() {
//     var absent = $(this).prop("checked")
//     var bowler = $(this).parents(".bowler")
//
//     if (absent) {
//       bowler.addClass("absent")
//       bowler.find(".absent-bowler").removeClass("hidden")
//       bowler.find(".shot").val("").attr("data-score", "")
//     } else {
//       bowler.removeClass("absent")
//       bowler.find(".absent-bowler").addClass("hidden")
//       // Remove absent frame scores
//       bowler.find(".score").text("")
//     }
//     calcScores()
//   })
//
//   $(document).on("change", ".skip-checkbox", function() {
//     var skip = $(this).prop("checked")
//     var bowler = $(this).parents(".bowler")
//
//     if (skip) {
//       bowler.addClass("skip")
//       bowler.find(".skip-bowler").removeClass("hidden")
//     } else {
//       bowler.removeClass("skip")
//       bowler.find(".skip-bowler").addClass("hidden")
//     }
//   })
////
//   updateTenthFallenPins = function() {
//     var toss = $(".shot.current")
//     var shot_idx = shotIndex(toss)
//
//     // Reset all pins
//     $(".pin-wrapper").removeClass("fallen").removeClass("fallen-before")
//     // Always knock the current pins down
//     knockPinsForShot(toss, "fallen")
//
//     if (shot_idx == 0) {
//       return // Don't do a full pin reset
//     } else if (shot_idx == 1) {
//       if (currentTossAtIdx(0).val() == "X") {
//         // DO do a full pin reset since we should have a full rack
//       } else {
//         return knockPinsForShot(currentTossAtIdx(0), "fallen-before")
//       }
//     } else if (shot_idx == 2) {
//       if (currentTossAtIdx(1).val() != "X" && currentTossAtIdx(1).val() != "/") {
//         return knockPinsForShot(currentTossAtIdx(1), "fallen-before")
//       }
//     }
//
//     // Else consider pin full reset, so knock all pins over by default
//     $(".pin-wrapper").addClass("fallen").removeClass("fallen-before")
//   }
//
//   knockPinsForShot = function(shot, klass) {
//     var pins_kept = fallenPinsForShot(shot).val()
//     $(".pin-wrapper").removeClass(klass)
//
//     if (pins_kept) {
//       var pins = JSON.parse(pins_kept)
//       var knocked = pinsKnocked(pins)
//       knocked.forEach(function(pin) {
//         $(".pin-wrapper[data-pin-num=" + pin + "]").addClass(klass)
//       })
//     } else {
//       // Start of frame
//       if (parseInt(shot.attr("data-shot-idx")) == 0) { // || last shot was strike
//         $(".pin-wrapper").addClass("fallen")
//       }
//     }
//   }
//
//   updateFallenPins = function() {
//     var toss = $(".shot.current")
//
//     if (toss.parents(".frame").attr("data-frame") == "10") { return updateTenthFallenPins() }
//
//     var prev_shot = toss.parents(".frame").find(".shot[data-shot-idx=" + (parseInt(toss.attr("data-shot-idx")) - 1) + "]")
//
//     knockPinsForShot(prev_shot, "fallen-before")
//     knockPinsForShot(toss, "fallen")
//     if ($(".fallen").length == 0) { pinTimer = clearTimeout(pinTimer) }
//   }
//
//   currentTossAtIdx = function(idx) {
//     return $(".shot.current").parents(".frame").find(".shot[data-shot-idx=" + idx + "]")
//   }
//
//
//   recountPins = function() {
//     pinTimer = clearTimeout(pinTimer)
//     var toss = $(".shot.current")
//     var pins = $(".pin-wrapper:not(.fallen, .fallen-before)").map(function() {
//       return parseInt($(this).attr("data-pin-num"))
//     }).toArray()
//     var first_throw = (shotIndex(toss) == 0 || (shotIndex(toss) == 1 && currentTossAtIdx(0).attr("data-score") == 10))
//
//     applyFrameModifiers(toss)
//
//     // Store the pins that are still standing in the current throw
//     toss.parents(".frame").find(".fallen-pins[data-shot-idx=" + toss.attr("data-shot-idx") + "]").val("[" + pins.join() + "]")
//     addScore($(".pin-wrapper.fallen:not(.fallen-before)").length, true)
//     // If pins have changed, knock down the ones for the next throw as well
//     if (first_throw) {
//       var next_fallen = toss.parents(".frame").find(".fallen-pins[data-shot-idx=" + (shotIndex(toss) + 1) + "]")
//       if (next_fallen.val().length > 0) {
//         var next_pins = JSON.parse(next_fallen.val()).filter(function(pin) {
//           return pins.includes(pin)
//         })
//
//         next_fallen.val("[" + next_pins.join() + "]")
//         var next_shot = toss.parents(".frame").find(".shot[data-shot-idx=" + (shotIndex(toss) + 1) + "]")
//         addScore(pins.length - next_pins.length, true, next_shot)
//       }
//     }
//
//     recalculateFrame(toss)
//     calcScores()
//   }
//
//   applyFrameModifiers = function(toss) {
//     let first_throw = (shotIndex(toss) == 0 || (shotIndex(toss) == 1 && currentTossAtIdx(0).attr("data-score") == 10))
//     if (!first_throw) { return }
//
//     let frame = $(toss).parents(".frame")
//     let pins = JSON.parse(frame.find(`.fallen-pins[data-shot-idx='${toss.attr("data-shot-idx")}']`).val() || "[]")
//     if (isSplit(pins)) {
//       toss.parents(".split-holder").addClass("split")
//     } else {
//       toss.parents(".split-holder").removeClass("split")
//     }
//   }
//
//   clearScores = function() {
//     $(".shot").each(function() { clearShot(this) })
//     calcScores()
//     pushScores()
//   }
//
//   fillRandomScores = function() {
//     var hold = should_check_stats
//     should_check_stats = false
//     while($(".shot.current").length > 0) {
//       addScore(Math.floor(Math.random() * 11))
//     }
//     should_check_stats = hold
//   }
//
//   $(document).on("click", ".shot", function() {
//     moveToThrow($(this))
//     $(this).blur()
//   }).on("click", ".bowling-navigation .nav-buttons", function(evt) {
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
//   $("form.bowling-game-form").submit(function(evt) {
//     evt.preventDefault()
//
//     if (inProgress) {
//       if (!confirm("The game is not complete. Are you sure you want to continue?")) {
//         return false
//       }
//     }
//     if ($(".card-point").length == 0 && $(".bowler").length > 1) {
//       if (!confirm("You did not enter a winner for cards. Are you sure you want to continue?")) {
//         return false
//       }
//     }
//
//     $(".bowling-form-btn").val("Saving...")
//
//     var form = $(this)
//     $.ajax({
//       type: form.attr("method"),
//       url: form.attr("action"),
//       data: form.serialize()
//     }).done(function(data) {
//       window.location.href = data.redirect
//     }).fail(function() {
//       $(".bowling-form-btn").html("Try Again")
//     })
//   })
//
//   $(".bowling-input .numpad-key.entry").click(function() {
//     $(".pin-wrapper").removeClass("fallen").removeClass("fallen-before")
//     $(".shot.current").parents(".frame").find(".fallen-pins").val("")
//     addScore($(this).text())
//   })
//
//   $(".bowling-cell.total .remove").click(function() {
//     $(this).parents(".bowling-table").remove()
//   })
//
//   $(".backspace").click(function() {
//     backspace()
//   })
//
//   $(document).on("click", ".bowler-name", function() {
//     if ($(this).find(".card-point").length > 0) {
//       $(".card-point-field").val(false)
//       $(".card-point").remove()
//     } else {
//       $(".card-point-field").val(false)
//       $(".card-point").remove()
//       var card = $("<div>").addClass("card-point").text("+1")
//       $(this).append(card)
//       $(this).parent().find(".card-point-field").val(true)
//     }
//   })
//
//   $(document).keyup(function(evt) {
//     if (evt.target?.closest(".lane-input")) { return }
//
//     if (/[0-9\/\+\-]/i.test(evt.key)) {
//       var num = evt.key == "+" ? "X" : evt.key
//       addScore(num)
//     } else if (evt.key == "Backspace" || evt.key == "Delete") {
//       backspace()
//     }
//   })
//
//   resetPinFall = function() {
//     // $(".pin-wrapper:not(.fallen-before)").addClass("fallen")
//     $(".pin-wrapper").addClass("fallen").removeClass("fallen-before")
//   }
//
//   throwScore = function(text) {
//     var score = text
//     score = score == "" ? null : parseInt(score)
//     return isNaN(score) ? null : score
//   }
//
//   collectThrows = function(bowler, include_perfect) {
//     return $(bowler).find(".bowling-cell.frame").map(function() {
//       var frame = $(this)
//       return [$(this).find(".shot").map(function() {
//         var score = throwScore($(this).attr("data-score"))
//
//         if (include_perfect && score == null) {
//           var shot_idx = frame.find(".shot").index($(this))
//           if (shot_idx > 0) {
//             var prev_throw = $(frame.find(".shot")[shot_idx - 1])
//
//             if (shot_idx == 2) { // Tenth frame, 3rd throw
//               var first_throw = $(frame.find(".shot")[0])
//               var first_open = first_throw.val() && first_throw.val() != "/" && first_throw.val() != "X"
//               var second_open = prev_throw.val() && prev_throw.val() != "/" && prev_throw.val() != "X"
//               if (first_open && second_open) {
//                 score = null
//                 return
//               }
//             }
//             if (prev_throw.val() != "/" && prev_throw.val() != "X") {
//               var prev_score = throwScore(prev_throw.attr("data-score"))
//               score = 10 - prev_score
//             } else if (frame.attr("data-frame") == "10") {
//               score = 10
//             } else {
//               score = null
//             }
//           } else {
//             score = 10
//           }
//         }
//
//         return score
//       }).toArray()]
//     }).toArray()
//   }
//
//   sumScores = function(arr) {
//     return arr.reduce(function(a, b) {
//       return parseInt(a) + parseInt(b)
//     }, 0)
//   }
//
//   calcFrameScores = function(score_array) {
//     var running_total = 0
//     var still_calc = true
//
//     return score_array.map(function(tosses, idx) {
//       var frame_total = 0
//       var first = tosses[0]
//       var second = tosses[1]
//
//       if (first == null) { still_calc = false }
//       if (idx == 9) { // Tenth frame
//         frame_total = sumScores(tosses)
//       } else if (first == 10) { // Strike
//         var next_tosses = score_array[idx + 1]
//         if (next_tosses[0] == 10) { // Next frame is also a strike
//           var more_tosses = score_array[idx + 2] || []
//           next_tosses = next_tosses.concat(more_tosses)
//         }
//         frame_total = 10 + sumScores(next_tosses.slice(0, 2))
//       } else if (first + second == 10) { // Spare
//         var next_tosses = score_array[idx + 1] || []
//         frame_total = 10 + sumScores(next_tosses.slice(0, 1))
//       } else { // Open frame
//         frame_total = sumScores(tosses)
//       }
//
//       if (still_calc) {
//         return running_total += frame_total
//       }
//     })
//   }
//
//   recalcScores = function() {
//     var low_frame = 10
//     $(".bowling-table.bowler:not(.absent, .skip)").each(function() {
//       var bowler = $(this)
//       var frames = bowler.find(".bowling-cell.frame")
//       frames.each(function() {
//         var toss = $(this).find(".shot").first()
//         if (toss.val() != "") {
//           recalculateFrame(toss)
//           var frame_pos = parseInt(toss.attr("data-frame"))
//           if (low_frame < frame_pos) { low_frame = frame_pos }
//         }
//       })
//     })
//
//     calcScores()
//     moveToNextFrame()
//   }
//
//   calcScores = function() {
//     detectDrinkFrames()
//     detectCleanStarts()
//     var team_total = 0
//     var team_hdcp = 0
//     var frame_num = findCurrentFrame()
//
//     $(".bowling-table.bowler").each(function(bowler_idx) {
//       var bowler = $(this)
//       var absent = bowler.hasClass("absent")
//       var frames = bowler.find(".bowling-cell.frame")
//
//       if (absent) {
//         var absent_score = parseInt(bowler.attr("data-absent-score")) || 0
//         var absent_frame_score = Math.floor(absent_score / 10)
//         var current_final_score = absent_frame_score * frame_num
//         if (frame_num >= 10) { current_final_score = absent_score }
//         var max_final_score = absent_score
//
//         frames.toArray().forEach(function(frame, idx) {
//           if (idx + 1 > frame_num) {
//             $(frame).find(".score").text("")
//           } else if (idx == 9) { // Tenth frame
//             $(frame).find(".score").text(max_final_score)
//           } else {
//             $(frame).find(".score").text(absent_frame_score * (idx + 1))
//           }
//         })
//       } else {
//         var current_game = calcFrameScores(collectThrows(bowler))
//         var max_game = calcFrameScores(collectThrows(bowler, true))
//
//         var squished_game = current_game.filter(function(score) { return score !== undefined })
//         var current_final_score = squished_game[squished_game.length - 1] || 0
//         var max_final_score = max_game[max_game.length - 1]
//
//         current_game.forEach(function(frame_score, idx) {
//           $(frames[idx]).find(".score").text(frame_score)
//         })
//       }
//
//       bowler.find(".total").find(".max").text("(max: " + max_final_score + ")")
//       team_hdcp += parseInt(bowler.find(".total").find(".hdcp").attr("data-base") || 0)
//       bowler.find(".total").find(".hdcp").text(function() {
//         if ($(this).attr("data-base")) {
//           return (parseInt($(this).attr("data-base")) || 0) + current_final_score
//         }
//       })
//       bowler.find(".total").find(".score").val(current_final_score)
//       team_total += current_final_score
//     })
//     var total_text = team_total
//     if (team_hdcp > 0) {
//       total_text = total_text + "|" + (team_total + team_hdcp)
//     }
//     $(".team-total").text(total_text)
//
//     inProgress = findCurrentFrame() < 11
//     if (findCurrentFrame() > 1 && !inProgress) {
//       $(".bowling-form-btn").removeClass("hidden")
//     }
//   }
//
//   detectCleanStarts = function() {
//     $(".perfect-game:not(.prev-score)").removeClass("perfect-game")
//     $(".consec-start").removeClass("consec-start")
//     $(".clean-start").removeClass("clean-start")
//     $(".bowler").each(function() {
//       let bowler = $(this)
//       let frameNum = parseInt(bowler.attr("data-current-frame"))
//       let currentVal = bowler.find(".frame[data-frame=" + frameNum + "] .shot[data-shot-idx=0]").val()
//
//       let consec = !currentVal || currentVal == "" || currentVal == "X", clean = true
//       for (var i=1; i<frameNum; i++) {
//         if (consec || clean) {
//           let first = bowler.find(".frame[data-frame=" + i + "] .shot[data-shot-idx=0]").val() || null
//           let second = bowler.find(".frame[data-frame=" + i + "] .shot[data-shot-idx=1]").val() || null
//           if (first != "X") { consec = false }
//           if (first && first != "X" && second != "/" && second != "X") { clean = false }
//         }
//       }
//       if (consec && frameNum == 11) { bowler.addClass("perfect-game") }
//       if (consec || clean) {
//         for (var i=1; i<frameNum; i++) {
//           let frame = bowler.find(".frame[data-frame=" + i + "]")
//           if (consec && frameNum == 11) { frame.addClass("perfect-game") }
//           if (consec) { frame.addClass("consec-start") }
//           if (clean) { frame.addClass("clean-start") }
//         }
//       }
//     })
//   }
//
//   detectDrinkFrames = function() {
//     $(".drink-frame").removeClass("drink-frame")
//     $(".missed-drink-frame").removeClass("missed-drink-frame")
//     if ($(".bowler:not(.absent, .skip)").length < 3) { return }
//
//     for (var i=1; i<=10; i++) {
//       let frames = $(".bowler:not(.absent, .skip) .frame[data-frame=" + i + "]")
//       let strikes = Array.from(frames).filter(function(frame) {
//         return $(frame).find(".shot[data-shot-idx=0]").val() == "X"
//       }).length
//
//       if (strikes == frames.length) {
//         frames.addClass("drink-frame")
//         $(".bowling-header .bowling-cell:contains(" + i + ")").filter(function() {
//           return $(this).text() == String(i)
//         }).addClass("drink-frame")
//       } else if (strikes == frames.length - 1) {
//         frames.each(function() {
//           if ($(this).find(".shot[data-shot-idx=0]").val() != "X" && $(this).find(".shot[data-shot-idx=0]").val() != "") {
//             $(this).addClass("missed-drink-frame")
//           }
//         })
//       }
//     }
//   }
//
//   recalculateFrame = function(toss) {
//     var frame = toss.parents(".frame")
//     var shots = frame.find(".shot")
//
//     var first_shot = $(shots[0])
//     var sec_shot = $(shots[1])
//
//     if (frame.attr("data-frame") == 10) {
//       shots.each(function(idx) {
//         if ($(this).val() == "") {
//           $(this).removeAttr("data-score")
//         } else if ($(this).val() == "/") {
//           $(this).attr("data-score", 10 - shotScore(shots[idx - 1]))
//         } else {
//           $(this).attr("data-score", shotScore(this))
//         }
//       })
//     } else {
//       if (first_shot.val() == "X") {
//         shots.val("").removeAttr("data-score")
//         first_shot.val("X").attr("data-score", 10)
//       } else if (sec_shot.val() == "/") {
//         var first_score = shotScore(first_shot)
//         first_shot.val(first_score || "-").attr("data-score", first_score)
//         sec_shot.val("/").attr("data-score", 10 - first_score)
//       } else {
//         shots.each(function() {
//           if ($(this).val() == "") {
//             $(this).removeAttr("data-score")
//           } else {
//             $(this).attr("data-score", shotScore(this))
//           }
//         })
//       }
//     }
//   }
//
//   backspace = function() {
//     var toss = $(".shot.current")
//     var frame = toss.parents(".frame")
//     var shots = frame.find(".shot")
//     var shot_idx = shots.index(toss)
//
//     if (shot_idx == 0) {
//       strikePoint(null)
//       shots.each(function() { clearShot(this) })
//     } else {
//       clearShot(toss)
//     }
//
//     updateFallenPins()
//     calcScores()
//     pushScores()
//   }
//
//   shotIndex = function(shot) {
//     var shot_idx = shot.attr("data-shot-idx")
//
//     return parseInt(shot_idx)
//   }
//
//   moveToEarliestThrow = function() {
//     var toss = $(".shot.current")
//     var earliest_empty_shot = toss.parents(".frame").find(".shot").filter(function() {
//       return !this.value
//     }).first()
//
//     if (shotIndex(earliest_empty_shot) < shotIndex(toss)) {
//       $(".shot.current").removeClass("current")
//       toss = earliest_empty_shot.addClass("current")
//     }
//   }
//
//   addScore = function(text, stay, toss) {
//     stay = stay || false
//     toss = toss || $(".shot.current")
//
//     moveToEarliestThrow()
//
//     if (currentFrame() == 10) { return addTenthFrameScore(text, stay, toss) }
//
//     var score = textToScore(text)
//     var prev_shot = $(toss.parents(".frame").find(".shot")[0])
//     var actual_val = scoreToVal(score, shotScore(prev_shot))
//     toss.attr("data-score", actual_val)
//
//     var shot_num = shotIndex(toss) + 1
//
//     if (shot_num == 1) {
//       if (score >= 10) {
//         toss.parents(".frame").find(".shot").val("") // Clear second shot
//         toss.val("X")
//         recalculateFrame(toss)
//         if (!stay) { moveToNextFrame() }
//       } else {
//         toss.val(score == "0" ? "-" : score)
//         recalculateFrame(toss)
//         if (!stay) { moveToNextThrow() }
//       }
//     } else if (shot_num == 2) {
//       if (prev_shot.val() == "X") {
//         if (!stay) { moveToNextFrame() }
//       }
//       // If first shot is blank, add score to first frame instead
//       if (prev_shot.val() == "") {
//         toss.removeAttr("data-score")
//         moveToThrow(prev_shot)
//         return addScore(score)
//       }
//
//       if (score + shotScore(prev_shot) >= 10) {
//         toss.val("/")
//       } else {
//         toss.val(score == "0" ? "-" : score)
//       }
//
//       recalculateFrame(toss)
//       if (!stay) { moveToNextFrame() }
//     }
//   }
//
//   // Dup?
//   clamp = (number, min, max) => Math.max(min, Math.min(number, max))
//   minMax = function(a, b, c) {
//     return [a, b, c].sort(function(x, y) { return x - y })[1]
//   }
//
//   // Dup?
//   scoreToVal = function(score, prev_score) {
//     prev_score = parseInt(prev_score) || 0
//     score = minMax(0, 10 - prev_score, textToScore(score))
//
//     if (!isNaN(score)) { return score }
//     if (score == "-") { return 0 }
//     if (score == "X") { return 10 }
//     if (score == "/") { return 10 - prev_score }
//     return 0
//   }
//   textToScore = function(text) {
//     if (text == "-") { return 0 }
//     if (text == "/") { return 10 }
//     if (text == "X") { return 10 }
//
//     return text == "" || isNaN(text) ? 0 : parseInt(text)
//   }
//   scoreFromToss = function(tossIdx, tosses) {
//     const toss = tosses[tossIdx]
//     if (!toss) return 0
//     if (toss === "-") return 0
//     if (toss === "X") return 10
//     if (toss === "/") return 10 - scoreFromToss(tossIdx-1, tosses)
//     return parseInt(toss)
//   }
//
//   addTenthFrameScore = function(score, stay, toss) {
//     stay = stay || false
//     toss = toss || $(".shot.current")
//     var shot_num = shotIndex(toss) + 1
//     var toss_score = textToScore(score)
//     var shots = toss.parents(".frame").find(".shot")
//     var prev_shot = $(shots[shot_num - 2])
//     var prev_score = shotScore(prev_shot)
//     var actual_val = 0
//
//     if (prev_shot.val() == "X" || prev_shot.val() == "/") {
//       actual_val = scoreToVal(score, 0) // After a close in the 10th, acts as a new frame
//     } else {
//       actual_val = scoreToVal(score, prev_score)
//     }
//     toss.attr("data-score", actual_val)
//
//     if (prev_shot.length > 0 && prev_score < 10 && prev_score + toss_score >= 10) {
//       toss.val("/")
//       if (!stay) { moveToNextThrow() }
//     } else if (toss_score >= 10) {
//       toss.val("X")
//       if (!stay) { moveToNextThrow() }
//     } else {
//       toss.val(score == "0" ? "-" : score)
//
//       if (!stay) {
//         if (shot_num == 1 || prev_score >= 10) { return moveToNextThrow() }
//         moveToNextFrame()
//       }
//     }
//   }
//
//   currentFrame = function() {
//     var toss = $(".shot.current")
//     var frame = toss.parents(".frame")
//
//     return parseInt(frame.attr("data-frame"))
//   }
//
//   currentThrowNum = function() {
//     var toss = $(".shot.current")
//     var frame = toss.parents(".frame")
//     var shots = frame.find(".shot")
//
//     return shots.index(toss) + 1
//   }
//
//   moveToThrow = function(toss) {
//     $(".shot.current").removeClass("current")
//     toss.addClass("current")
//     pinTimer = clearTimeout(pinTimer)
//     // $(".pin-wrapper:not(.fallen-before)").addClass("fallen")
//     // resetPinFall()
//     resetStrikePoint()
//     checkStats()
//     updateFallenPins()
//   }
//
//   checkStats = function() {
//     var stats = $(".stats-holder")
//     stats.html("")
//
//     if (!pin_mode_show || !should_check_stats) { return }
//
//     var toss = $(".shot.current")
//     if (toss.length == 0) { return }
//
//     var bowler_id = toss.parents(".bowler").attr("data-bowler-id")
//     if (bowler_id.length == 0) { return }
//
//     var shotIdx = shotIndex(toss)
//     var first_throw = shotIdx == 0
//     if (currentFrame() == 10) {
//       first_throw = first_throw || (shotIdx == 1 && currentTossAtIdx(0).attr("data-score") == 10)
//       first_throw = first_throw || (shotIdx == 2 && currentTossAtIdx(1).attr("data-score") == 10 || currentTossAtIdx(1).val() == "/")
//     }
//
//     var url = stats.attr("data-stats-url")
//
//     var pins
//     if (first_throw) {
//       pins = undefined
//     } else {
//       pins = fallenPinsForShot(currentTossAtIdx(shotIndex(toss) - 1)).val()
//     }
//
//     stats.html("<i class=\"fa fa-spinner fa-spin\"></i>")
//
//     $.get(url, { bowler_id: bowler_id, pins: pins }).done(function(data) {
//       stats.html("")
//       if (!data.stats.total) { return }
//       var nums = data.stats.spare + " / " + data.stats.total
//       var ratio = Math.round((data.stats.spare / data.stats.total) * 100)
//
//       $(".stats-holder").html(ratio + "%" + "</br>" + nums)
//     })
//   }
//
//   moveToNextThrow = function() {
//     calcScores()
//     var next_shot = currentTossAtIdx(parseInt($(".shot.current").attr("data-shot-idx")) + 1)
//
//     if (next_shot.length > 0) {
//       moveToThrow(next_shot)
//     } else {
//       moveToNextFrame()
//     }
//   }
//
//   findNextFrame = function(bowler) {
//     return bowler.find(".frame").filter(function() {
//       let shot0 = $(this).find(".shot[data-shot-idx=0]").val()
//       if (shot0 == "") { return true }
//
//       let shot1 = $(this).find(".shot[data-shot-idx=1]").val()
//       if (shot0 != "X" && shot1 == "") { return true }
//
//       if ($(this).attr("data-frame") == "10") {
//         let shot2 = $(this).find(".shot[data-shot-idx=2]").val()
//         if (shot0 == "X" && shot2 == "") { return true  }
//         if (shot0 != "X" && shot1 == "/" && shot2 == "") { return true  }
//         // True means frame is NOT complete
//       }
//     }).first()
//   }
//
//   findCurrentFrame = function() {
//     setFrames()
//     return Math.min.apply(Math, $(".bowler:not(.absent, .skip)").map(function() {
//       return parseInt($(this).attr("data-current-frame")) || 0
//     }))
//   }
//
//   setFrames = function() {
//     $(".bowling-table.bowler:not(.absent, .skip)").each(function() {
//       var bowler = $(this)
//       var current_frame = findNextFrame(bowler)
//
//       bowler.attr("data-current-frame", current_frame.attr("data-frame") || 11)
//     })
//   }
//
//   gotoNextFrame = function() {
//     setFrames()
//
//     var next_bowler = $(".bowling-table.bowler:not(.absent, .skip)").sort(function(a, b) {
//       a = $(a)
//       b = $(b)
//       var a_frame = parseInt(a.attr("data-current-frame"))
//       var b_frame = parseInt(b.attr("data-current-frame"))
//
//       if (a_frame == b_frame) {
//         var a_bowler = parseInt(a.attr("data-bowler"))
//         var b_bowler = parseInt(b.attr("data-bowler"))
//         return a_bowler - b_bowler
//       }
//
//       return a_frame - b_frame
//     }).first()
//
//     let toThrow = findNextFrame(next_bowler).find(".shot").filter(function() {
//       return !$(this).val()
//     }).first() || findNextFrame(next_bowler).find(".shot").first()
//
//     moveToThrow(toThrow)
//   }
//
//   shotScore = function(toss) {
//     var score = $(toss).val()
//
//     return textToScore(score)
//   }
//
//   gotoNextPlayer = function() {
//     calcScores()
//     $(".shot.current").removeClass("current")
//   }
//
//   moveToNextFrame = function() {
//     calcScores()
//     // If there are more players, should go to next bowler
//     if ($(".shot.current").parents(".frame").attr("data-frame") == "10") {
//       var frame_shots = $(".shot.current").parents(".frame").find(".shot")
//       if (shotScore(frame_shots[0]) + shotScore(frame_shots[1]) >= 10) {
//         if (currentThrowNum() < 3) { return moveToNextThrow() }
//       }
//     }
//     pushScores()
//     gotoNextFrame()
//   }
//
//   pushScores = function() {
//     if (currentScorePush) {
//       currentScorePush.abort()
//       currentScorePush = null
//     }
//
//     let form = $("form.bowling-game-form")
//     currentScorePush = $.ajax({
//       type: form.attr("method"),
//       url: form.attr("action"),
//       data: form.serialize() + "&throw_update=true"
//     })
//   }
//
//   $(".shot").filter(function() {
//     return !this.value
//   }).first().addClass("current")
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
//   setFrames() // Need this to set absent bowlers
//   recalcScores()
//   laneTalk()
// })
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
