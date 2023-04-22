export function showModal(id) {
  document.querySelector(`#${id}`).classList.add("show")
}
export function hideModal(id) {
  document.querySelector(`#${id}`).classList.remove("show")
}

document.querySelectorAll(".close").forEach((close) => {
  close.addEventListener("click", function(evt) {
    const target = evt.target.closest(".modal")

    target.classList.remove("show")
  })
})

export function resizeModal() {
  if (!window.visualViewport) { return }

  let modal = document.querySelector(".modal.show")
  if (modal) { modal.style.height = window.visualViewport.height - 40 + "px" }
  setTimeout(function() {
    let modal = document.querySelector(".modal.show")
    if (modal) { modal.style.height = window.visualViewport.height - 40 + "px" }
  }, 600)
}

window.addEventListener("resize", resizeModal)
window.addEventListener("focusout", function() {
  document.querySelector(".modal.show")?.classList?.remove("show")
  resizeModal()
})
document.querySelectorAll("input").forEach((input) => {
  input.addEventListener("focus", resizeModal)
  input.addEventListener("blur", resizeModal)
})
document.querySelectorAll(".modal").forEach((modal) => {
  modal.addEventListener("transitionend", resizeModal)
})

document.addEventListener("click", function(evt) {
  // Somehow detect an out-of-modal click
  // const modal = evt.target.closest(".modal")
  // const widget = evt.target.closest(".widget-wrapper")
  //
  // // debugger
  // if (!widget && !modal) {
  //   document.querySelector(".modal.show").classList.remove("show")
  // }
})
