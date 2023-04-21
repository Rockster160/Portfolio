export function showModal(id) {
  document.querySelector(`#${id}`).classList.add("show")
}
export function hideModal(id) {
  document.querySelector(`#${id}`).classList.remove("show")
}

document.querySelector(".close").addEventListener("click", function(evt) {
  const target = evt.target.closest("#command-modal")

  target.classList.remove("show")
})

document.addEventListener("click", function(evt) {
  // Somehow detect an off-modal click
  // const modal = evt.target.closest(".modal")
  // const widget = evt.target.closest(".widget-wrapper")
  //
  // // debugger
  // if (!widget && !modal) {
  //   document.querySelector(".modal.show").classList.remove("show")
  // }
})
