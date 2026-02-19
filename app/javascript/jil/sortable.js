import Sortable from "./Sortable.min.js"

// https://github.com/SortableJS/Sortable
export default function sortable(ele) {
  new Sortable(ele, {
    group: "blocks",
    handle: ".handle",
    draggable: ".statement-wrapper",
    animation: 150,
    onStart: function(evt) {
      document.querySelectorAll(".content").forEach(item => {
        let allowed = item.getAttribute("allowed")?.split("|")
        if (allowed && allowed.indexOf("Any") < 0) {
          let statement = Statement.from(evt.item)
          if (allowed.indexOf(statement.returntype) < 0) {
            return // Current object not allowed, don't open
          }
        }
        item.classList.add("open")
        item.classList.remove("collapsed")
      })
    },
    onEnd: function(evt) {
      document.querySelectorAll(".content.open").forEach(item => item.classList.remove("open"))
      let statement = Statement.from(evt.item)
      statement.moved()
      History.record()
    },
    onMove: function(evt) {
      const { related, to, originalEvent } = evt
      if (related.classList.contains("content-dropdown")) {
        if (related.classList.contains("below")) {
          if (evt.willInsertAfter) { // Do not allow elements to be dropped above the dropdown
            originalEvent.preventDefault()
            return false
          }
        } else {
          if (!evt.willInsertAfter) { // Do not allow elements to be dropped below the dropdown
            originalEvent.preventDefault()
            return false
          }
        }
      }
      if (to.hasAttribute("allowed")) {
        let allowed = to.getAttribute("allowed").split("|")
        if (allowed && allowed.indexOf("Any") < 0) {
          let statement = Statement.from(evt.dragged)
          if (allowed.indexOf(statement.returntype) < 0) {
            originalEvent.preventDefault()
            return false
          }
        }
      }
    },
  })
  return ele
}
