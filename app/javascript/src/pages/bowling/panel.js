import { onEvent, onKeyDown } from "./events"
import Rest from "./rest"

export function panel() {
  let editingBowler = null

  // onEvent("modal.hidden", function() {
  //   console.log("Hidden modal");
  // })
  // document.addEventListener("modal.hidden", function() {
  //   console.log("Hidden");
  // })

  onEvent("change", ".absent-checkbox, .skip-checkbox", function() {
    if (game.currentBowler?.active) { return }

    game.nextShot()
  })
  onEvent("click", ".bowling-cell .remove", (evt) => game.removeBowler(game.bowlerFrom(evt.target)))
  onEvent("click", ".new-bowler", (evt) => {
    showBowlerModal(evt)

    showModal("#bowler-sub-list")
  })
  onEvent("click", ".bowler-sub-btn", (evt) => {
    showBowlerModal(evt)

    editingBowler = game.bowlerFrom(evt.target)
    let nameEle = document.querySelector(".sub-out-name")
    nameEle.text = editingBowler.bowlerName
    nameEle.setAttribute("data-bowler-id", editingBowler.serverId)
    document.querySelector(".sub-message").classList.remove("hidden")

    showModal("#bowler-sub-list")
  })

  onEvent("click", ".bowler-form.bowler-select", (evt) => {
    let bowlerData = gatherData(evt.target)
    if (editingBowler) { bowlerData.bowlerNum = editingBowler.bowlerNum }
    let bowler = game.addBowler(bowlerData)
    if (editingBowler) {
      game.removeBowler(editingBowler)
      editingBowler = null
    }

    hideModal("#bowler-sub-list")
    game.editBowler = true
  })
  onEvent("click", ".bowler-option", (evt) => {
    let opt = evt.target
    editingBowler = game.bowlerFrom(evt.target)

    let label = opt.getAttribute("data-bowler-option")
    let value = opt.querySelector(".option-value").innerText
    let newVal = window.prompt(`Enter new ${label}`, value)

    if (newVal) {
      if (label == "name") {
        editingBowler.bowlerName = newVal
      } else if (label == "avg") {
        editingBowler.avg = newVal
      } else if (label == "hdcp") {
        editingBowler.hdcp = newVal
      }
    }

    editingBowler = null
  })
  onEvent("submit", ".bowling-game-form", function(evt) {
    evt.preventDefault()
    return game.nextGame()
  })
  onEvent("submit", ".add-new-bowler", function(evt) {
    evt.preventDefault()
    let form = evt.target
    Rest.submit(form).then(json => {
      let json_bowler = json.bowler
      let bowler_data = {
        serverId:     json_bowler.id,
        bowlerName:   json_bowler.name,
        bowlerGameId: json_bowler.game_id,
        avg:          json_bowler.average,
        hdcp:         json_bowler.handicap,
        absentScore:  json_bowler.absent_score,
        usbcName:     json_bowler.usbc_name,
        usbcNumber:   json_bowler.usbc_number,
      }
      game.addBowler(bowler_data)

      hideModal("#bowler-sub-list")
      form.querySelector("#bowler_name").value = ""
      form.querySelector("#bowler_total_games_offset").value = ""
      form.querySelector("#bowler_total_pins_offset").value = ""
      form.querySelector("input[type='submit']").removeAttribute("disabled")

      game.editBowler = true
    })
  })

  let gatherData = function(wrapper) {
    let obj = {}
    wrapper.querySelectorAll("input").forEach(ele => {
      if (ele.name) { obj[ele.name] = ele.value }
    })
    return obj
  }

  let showBowlerModal = function(evt) {
    evt.preventDefault()
    evt.stopPropagation()
    document.querySelector(".sub-message").classList.add("hidden")
    document.querySelector(".bowler-select").classList.remove("hidden")
    document.querySelectorAll(".bowler-select").forEach(item => item.classList.remove("hidden"))
    game.eachBowler(bowler => {
      let selector = `.bowler-select[data-bowler-id="${bowler.serverId}"]`
      let ele = document.querySelector(selector)
      if (!ele) { return } // New bowlers don't need to show up in this
      ele.classList.add("hidden")
    })
  }
}
