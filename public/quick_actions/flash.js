export function showFlash(message) {
  const flash = document.createElement("div")
  flash.classList.add("flash")
  flash.innerText = message
  document.body.appendChild(flash)
  setTimeout(() => {
    flash.classList.add("show")
    setTimeout(() => {
      flash.classList.remove("show")
      setTimeout(() => {
        document.body.removeChild(flash)
      }, 500)
    }, 3000)
  }, 100)
}
