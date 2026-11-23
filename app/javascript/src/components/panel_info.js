// The ⓘ beside a panel setting: a tap shows its note, and a tap anywhere else
// closes it. Inside a <label>, a tap on the note would flip the label's switch,
// so that tap goes no further.
document.addEventListener("click", function(evt) {
  if (evt.target.closest(".panel-info-tip")) {
    evt.preventDefault()
    return
  }

  const button = evt.target.closest("[data-panel-info]")
  document.querySelectorAll("[data-panel-info][aria-expanded=true]").forEach(function(open) {
    if (open === button) return

    open.setAttribute("aria-expanded", "false")
    open.nextElementSibling.hidden = true
  })
  if (!button) return

  evt.preventDefault()
  const showing = button.getAttribute("aria-expanded") === "true"
  button.setAttribute("aria-expanded", String(!showing))
  button.nextElementSibling.hidden = showing
})
