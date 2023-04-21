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

export function resizeModal() {
  if (!window.visualViewport) { return }

  setTimeout(function() {
    // This works when pasting into the console, but breaks on deploy. :(
    document.querySelector("html").style.height = window.visualViewport.height + "px"
    document.querySelector("body").style.height = window.visualViewport.height + "px"
    document.querySelector(".modal.show").style.height = window.visualViewport.height - 40 + "px"
  }, 600)
}

window.addEventListener("resize", resizeModal)
document.querySelectorAll("input").forEach((input) => {
  input.addEventListener("focus", resizeModal)
})
document.querySelectorAll(".modal").forEach((item, i) => {
  item.addEventListener("transitionend", resizeModal)
});

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
