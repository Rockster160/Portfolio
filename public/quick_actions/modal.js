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

export function resizeModal() {
  if (!window.visualViewport) { return }

  let modal = document.querySelector(".modal.show#command-modal")
  if (modal) { modal.style.height = window.visualViewport.height - 40 + "px" }
  setTimeout(function() {
    let modal = document.querySelector(".modal.show#command-modal")
    if (modal) { modal.style.height = window.visualViewport.height - 40 + "px" }
  }, 600)
}

document.addEventListener("click", function(evt) {
  if (evt.target.closest(".close")) {
    evt.target.classList.closest(".modal").remove("show")
  }
})

window.addEventListener("resize", resizeModal)
window.addEventListener("focusout", function() {
  // document.querySelector(".modal.show")?.classList?.remove("show")
  resizeModal()
})
document.querySelectorAll("input").forEach((input) => {
  input.addEventListener("focus", resizeModal)
  input.addEventListener("blur", resizeModal)
})
document.querySelectorAll(".modal").forEach((modal) => {
  modal.addEventListener("transitionend", resizeModal)
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
