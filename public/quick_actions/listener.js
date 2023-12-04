// Add listeners here to ensure highest priority
document.addEventListener("click", function(evt) {
  if (!evt.target.classList.contains("delete-widget")) { return }

  evt.stopPropagation()
  evt.preventDefault()
  evt.target.parentElement.remove()
  return false
})
