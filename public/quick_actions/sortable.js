import Sortable from "https://cdn.jsdelivr.net/npm/@shopify/draggable/build/esm/Sortable/Sortable.mjs"

const sortable = new Sortable(document.querySelectorAll(".widget-wrapper"), {
  draggable: ".widget-holder.jiggle",
})

let modes = ["use", "add", "move", "delete"]
let mode = 0

document.addEventListener("click", function(evt) {
  if (!evt.target.classList.contains("delete-widget")) { return }

  evt.preventDefault()
  evt.stopPropagation()
  evt.target.parentElement.remove()
  return false
})

document.addEventListener("click", function(evt) {
  let new_mode_name = evt.target.getAttribute("data-mode")
  if (!new_mode_name) { return }

  let new_mode = modes.indexOf(new_mode_name)
  if (mode == new_mode) {
    console.log("Toggle OFF!");
    new_mode = 0
    new_mode_name = modes[0]
  }
  mode = new_mode

  document.querySelectorAll(`[data-mode]`).forEach(item => {
    item.classList.remove("active")
    let item_mode = item.getAttribute("data-mode")
    let capital_mode = item_mode.charAt(0).toUpperCase() + item_mode.slice(1)
    item.text = capital_mode

    document.querySelectorAll(".jiggle").forEach(item => item.classList.remove("jiggle"))
    document.querySelectorAll(".delete-widget").forEach(item => item.classList.add("hidden"))
  })

  document.querySelectorAll(`[data-mode="${new_mode_name}"]`).forEach(item => {
    evt.target.text = "Done"
  })

  if (new_mode_name == "add") {
    console.log("Pop new modal!");
  } else if (new_mode_name == "move") {
    document.querySelectorAll(".widget-holder").forEach(item => item.classList.add("jiggle"))
  } else if (new_mode_name == "delete") {
    document.querySelectorAll(".delete-widget").forEach(item => item.classList.remove("hidden"))

    console.log("Add Delete buttons!");
  }
})

// .draggable-source--is-dragging // -- placeholder
// .draggable-mirror // -- held item (ghost)

// sortable.on("sortable:start", () => console.log("sortable:start"))
// sortable.on("sortable:sort", () => console.log("sortable:sort"))
// sortable.on("sortable:sorted", function(e) {
//   debugger
//   console.log("sortable:sorted")
// })
// sortable.on("sortable:stop", () => console.log("sortable:stop"))



// window.addEventListener("mousedown", function(e) {
//   if (e.button == 2) {
//     if (document.querySelector(".modal.show")) {
//       document.querySelectorAll(".modal.show .widget-holder").forEach((item) => {
//         item.classList.toggle("jiggle")
//       })
//     } else {
//       document.querySelectorAll(".widget-wrapper > .widget-holder").forEach((item) => {
//         item.classList.toggle("jiggle")
//       })
//     }
//   }
// })
