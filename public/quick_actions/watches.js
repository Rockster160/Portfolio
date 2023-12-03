let showWatcher = function(watcher) {
  watcher.classList.remove("hidden")
  watcher.querySelectorAll("input, textarea, button").forEach(function(ele) {
    ele.disabled = false
    ele.readOnly = false
    ele.removeAttribute("form")
  })
}

let hideWatcher = function(watcher) {
  watcher.classList.add("hidden")
  watcher.querySelectorAll("input, textarea, button").forEach(function(ele) {
    ele.disabled = true
    ele.readOnly = true
    ele.setAttribute("form", "none")
  })
}

document.querySelectorAll("[data-watches-selector]").forEach(function(element) {
  var watcher = element,
    watching = document.querySelector(watcher.getAttribute("data-watches-selector"))

  let reactToChange = function() {
    let val = watcher.getAttribute("data-watches-value")
    let invert = false
    if (val.startsWith("!")) {
      val = val.replace("!", "")
      invert = true
    }
    let match = watching.value == val
    if (invert ? !match : match) {
      showWatcher(watcher)
    } else if (
      watcher.getAttribute("data-watches-radio") &&
      document.querySelector(watcher.getAttribute("data-watches-selector") + ":checked")?.value ==
        watcher.getAttribute("data-watches-radio")
    ) {
      showWatcher(watcher)
    } else {
      hideWatcher(watcher)
    }
  }

  reactToChange()
  watching.addEventListener("change", reactToChange)
})
