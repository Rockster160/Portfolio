import Sortable from "https://cdn.jsdelivr.net/npm/@shopify/draggable/build/esm/Sortable/Sortable.mjs"

const sortable = new Sortable(document.querySelectorAll(".widget-wrapper"), {
  draggable: ".widget-holder.jiggle",
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
