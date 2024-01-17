import { onEvent, onKeyDown } from "./events"

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
  onEvent("click", ".bowling-cell .remove", (evt) => game.bowlerFrom(evt.target).remove())
  onEvent("click", ".new-bowler", (evt) => {
    showBowlerModal(evt)

    showModal("#bowler-sub-list")
  })
  onEvent("click", ".bowler-sub-bowler", (evt) => {
    showBowlerModal(evt)
    document.querySelector(".sub-message").classList.remove("hidden")

    editingBowler = game.bowlerFrom(evt.target)
    let nameEle = document.querySelector(".sub-out-name")
    nameEle.text = editingBowler.name
    nameEle.setAttribute("data-bowler-id", editingBowler.serverId)

    showModal("#bowler-sub-list")
  })

  onEvent("click", ".bowler-form.bowler-select", (evt) => {
    let bowlerData = gatherData(evt.target)
    if (editingBowler) { bowlerData.bowlerNum = editingBowler.bowlerNum }
    let bowler = game.addBowler(bowlerData)
    if (editingBowler) {
      editingBowler.remove()
      editingBowler = null
    }

    hideModal("#bowler-sub-list")
    game.skipSaveAfterEdit = true
    game.editBowler = false

    // bowling-game-template
    // var out_bowler_id = $(".sub-out-name").attr("data-bowler-id")
    // var in_bowler_id = $(this).attr("data-bowler-id")
    //
    // var in_bowler = $($("#game-sub-list").get(0).content).find(".bowler[data-bowler-id=" + in_bowler_id + "]")
    // var out_bowler = $(".bowler[data-bowler-id=" + out_bowler_id + "]")
    //
    // hideModal("#bowler-sub-list")
    // if (out_bowler.length > 0) {
    //   swap(in_bowler, out_bowler)
    // } else {
    //   $(in_bowler).insertBefore(".bowler-placeholder")
    // }
    // resetEdits()
    // calcScores()
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
      if (!ele) { debugger}
      ele.classList.add("hidden")
    })
  }
}
