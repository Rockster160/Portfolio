// Add listeners here to ensure highest priority
document.addEventListener("click", function(evt) {
  // Do not click the element underneath the overlay when it's open
  if (evt.target.matches(".widget-overlay-btn")) {
    evt.stopPropagation()
    evt.preventDefault()

    return false
  }
})
