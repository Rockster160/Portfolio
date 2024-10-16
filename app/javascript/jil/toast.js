export default class Toast {
  static createToast(msg, type, duration) {
    const toast = document.createElement("div")
    toast.className = `toast toast-${type}`
    if (typeof msg === "string") {
      toast.innerText = msg
    } else {
      toast.appendChild(msg)
    }

    toast.onclick = () => this.dismissToast(toast)
    document.body.appendChild(toast)

    setTimeout(() => toast.classList.add("show"), 100)
    if (duration) {
      setTimeout(() => this.dismissToast(toast), duration)
    }
  }

  static success(msg, duration) {
    this.createToast(msg, "success", duration)
  }

  static error(msg, duration) {
    this.createToast(msg, "error", duration)
  }

  static info(msg, duration) {
    this.createToast(msg, "info", duration)
  }

  static dismissToast(toast) {
    toast.classList.remove("show")
    toast.addEventListener("transitionend", () => toast.remove())
  }
}

// Add styles for the toast (can be included in your CSS file)
// const style = document.createElement("style")
// style.innerHTML = `
// `
// document.head.appendChild(style)
