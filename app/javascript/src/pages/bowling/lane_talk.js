export default class LaneTalk {
  constructor(start_lane, enabled) {
    this.startLane = start_lane
    this.uuid = this.genUUID()
    this.currentGame = game.gameNum
    this.centerId = document.querySelector(".league-data").getAttribute("data-lanetalk-center-id")
    this.apiKey = document.querySelector(".league-data").getAttribute("data-lanetalk-key")

    if (!this.centerId || !this.apiKey) {
      if (this.enabled && this.startLane) {
        if (!this.centerId) { console.error("[ERROR][LaneTalk] Missing Center ID") }
        if (!this.apiKey) { console.error("[ERROR][LaneTalk] Missing LaneTalk API Key") }
      }
      return
    }

    this.enabled = enabled
  }

  get enabled() { return this._enabled }
  set enabled(bool) {
    this._enabled = bool
    if (bool) {
      this.connectWS()
    } else {
      this.socket?.close()
    }
  }

  active() { return this.centerId && this.apiKey && this.enabled && this.startLane }

  connectWS() {
    if (!this.active()) { return }

    this.socket?.close()
    this.socket = new WebSocket("wss://ws.lanetalk.com/ws")
    let talk = this

    talk.socket.addEventListener("open", function(event) {
      talk.retryTimer = clearTimeout(talk.retryTimer)
      talk.send({
        id: talk.uuid,
        method: 0,
        params: { api_key: talk.apiKey }
      })
    })

    talk.socket.addEventListener("message", function(event) {
      if (!talk.active()) { return }

      let json = JSON.parse(event.data)
      let result = json.result || {}
      if (result.result?.client) {
        talk.send({
          id: talk.uuid,
          method: 1,
          params: { channel: `LiveScores:${talk.centerId}` }
        })
      } else if (Object.keys(result).length > 0) {
        if (result.type == 5) { // Single player
          talk.updatePlayer(result.data)
        } else { // Entire alley
          console.log("All data came back!", json.result.publications[0].data.lanes);
          json.result.publications[0].data.lanes.forEach(function(player) {
            talk.updatePlayer(player)
          })
        }
      }
    })

    talk.socket.addEventListener("close", function(event) {
      talk.retryTimer = clearTimeout(talk.retryTimer)
      talk.retryTimer = setTimeout(function() {
        talk.connectWS()
      }, 5000)
    })
  }

  updatePlayer(player) {
    // {
    //   "bowlingCenterUuid": "xxx-xxx-xxx-xxx",
    //   "lane": 22,
    //   "game": 2,
    //   "crossLane": false,
    //   "playerName": "Lisa Taylor",
    //   "playerNumber": 2,
    //   "playerHcp": 83,
    //   "teamName": "Flying Balls",
    //   "teamHcp": 193,
    //   "scoreCompletedGames": 167,
    //   "throws": [1, 3, 7, "/", 9, "-", 7, "-"],
    //   "pins": [511, 311, 52, 0, 512, 512, 11, 11],
    //   "scores": [4, 23, 32, 39],
    //   "speed": [3023, 3543, 3082, 3082, 3152, 3152, 3200, 2729],
    //   "belongsTo": null,
    //   "received": 1701995577,
    //   "maxScore": 210
    // }
    if (player.game != this.currentGame) { return }
    if (player.lane == this.siblingLane) { return this.updateEnemy(player) }
    if (player.lane != this.currentLane) { return }
    console.log("Player", player);

    let bowler = game.bowlers[player.playerNumber]
    if (!bowler) { return console.log("No bowler", player); }

    // crossLane
    // playerName
    // playerNumber
    // playerHcp
    // teamName
    // teamHcp
    bowler.shots.forEach((shot, idx) => {
      let binaryPinCount = player.pins[idx]
      if (typeof binaryPinCount == "number") {
        shot.score = binaryPinCount
      } else {
        shot.clear(true)
      }
    })
    if (!game.pinTimer.running()) {
      game.nextShot()
    }
  }

  updateEnemy(player) {
    console.log("Enemy", player);
  }

  send(json) {
    this.socket.send(JSON.stringify(json))
  }

  genUUID() {
    return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, function(c) {
      const r = (Math.random() * 16) | 0
      const v = c === "x" ? r : (r & 0x3) | 0x8
      return v.toString(16)
    })
  }

  get startLane() { return this._start_lane }
  set startLane(lane) {
    this._start_lane = parseInt(lane)
    this.currentLane = this.findCurrentLane(this._start_lane)
    this.siblingLane = this.findSiblingLane(this.currentLane)
  }

  findSiblingLane(start_lane) { return start_lane + (start_lane % 2 ? 1 : -1) }
  findCurrentLane(start_lane) {
    return (game.gameNum % 2 == 1) ? start_lane : this.findSiblingLane(start_lane)
  }
}

// {
//   "result": {
//     "channel": "LiveScores:xxx-xxx-xxx-xxx",
//     "type": 5,
//     "data": {
//       "bowlingCenterUuid": "xxx-xxx-xxx-xxx",
//       "lane": 22,
//       "game": 2,
//       "crossLane": false,
//       "playerName": "Lisa Taylor",
//       "playerNumber": 2,
//       "playerHcp": 83,
//       "teamName": "Flying Balls",
//       "teamHcp": 193,
//       "scoreCompletedGames": 167,
//       "throws": [1, 3, 7, "/", 9, "-", 7, "-"],
//       "pins": [511, 311, 52, 0, 512, 512, 11, 11],
//       "scores": [4, 23, 32, 39],
//       "speed": [3023, 3543, 3082, 3082, 3152, 3152, 3200, 2729],
//       "belongsTo": null,
//       "received": 1701995577,
//       "maxScore": 210
//     }
//   }
// }

//
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




//     let bowler_mapping = {}
//     $(".bowler").each(function() {
//       let bowlerNum = this.getAttribute("data-bowler")
//
//       if (bowlerNum) { bowler_mapping[parseInt(bowlerNum)] = this }
//     })
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
