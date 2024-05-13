export function showModal(id) {
  document.querySelector(`#${id}`)?.classList?.add("show")
}
export function hideModal(id) {
  document.querySelector(`#${id}`)?.classList?.remove("show")
}
export function hideCurrentModal() {
  let open_modals = document.querySelectorAll(".modal.show")
  open_modals[open_modals.length -1]?.classList?.remove("show")
}

document.addEventListener("click", function(evt) {
  if (evt.target.closest(".close")) {
    evt.target.closest(".modal").classList.remove("show")
  }
  if (evt.target.tagName == "BODY") {
    hideCurrentModal()
  }
})

document.addEventListener("keydown", function(event) {
  if (event.key === "Escape") {
    hideCurrentModal()
  }
})

document.addEventListener("click", function(evt) {
  if (evt.cancelBubble) { return }

  let x = evt.clientX, y = evt.clientY
  let w = window.outerWidth, h = window.outerHeight

  if (x < 30 || y < 30 || x > w-30 || y > h-30) {
    hideCurrentModal()
  }
  let modal_id = evt.target.closest("[data-modal]")?.getAttribute("data-modal")
  if (modal_id) {
    showModal(modal_id)
  }
})
