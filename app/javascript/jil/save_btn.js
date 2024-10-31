// Use:
//   const btn = new SaveBtn(document.querySelector(".my-button"))
//   btn.onClick(() => {
//     // Submit whatever data to the server
//   })
//   // async must be used in order to catch errors that occur in an await (like fetch)
//   btn.onClick(async () => {
//     await fetch(...)
//   }).onSave(() => {}).onSaveDone(() => {}).onError(() => {})
// Styles:
//   .btn-success (applied and immediately removed with a delayed background color fade)
//   .btn-error   (applied indefinitely after an error until clicked again to retry)
//   .btn-pending (applied while onClick callback is running)
export default class SaveBtn {
  constructor(element) {
    this.btn = element
    this._saving = false
    this._error = null
    this.flashTimer = undefined
  }

  get saving() { return this._saving }
  set saving(bool) {
    this._error = null
    if (bool && !this._saving) {
      this.trigger("save-start")
    } else if (!bool && this._saving) {
      this.trigger("save-success")
    }
    this._saving = bool
    this.updateState()
  }

  get error() { return this._error }
  set error(msg) {
    console.error(msg)
    this.trigger("error", msg)
    this._saving = false
    this._error = msg
    this.updateState()
  }

  trigger(key, data) {
    this.btn.dispatchEvent(new CustomEvent(`save-btn:${key}`, {
      detail: data || {},
    }))
  }

  success() {
    this.saving = false
    let originalColor = window.getComputedStyle(this.btn).backgroundColor;
    this.btn.style.transition = "background-color 0s";
    this.btn.classList.add("btn-success")

    setTimeout(() => {
      this.btn.style.transition = "background-color 2s";
      this.btn.classList.remove("btn-success")
    }, 100);
    this.flashTimer = setTimeout(() => {
      this.btn.style.transition = "background-color 0s";
    }, 2000);
  }

  updateState() {
    clearTimeout(this.flashTimer)
    this.btn.style.transition = "background-color 0s";
    this.btn.classList.remove("btn-success")

    if (this.error) {
      this.btn.title = this.error
    } else {
      this.btn.removeAttribute("title")
    }
    this.btn.classList.toggle("btn-error", this.error)
    this.btn.classList.toggle("btn-pending", this.saving)
    this.btn.disabled = this.saving
  }

  async save(callback) {
    if (!this.btn || this.btn.disabled) { return }

    try {
      this.saving = true
      await callback()
      this.success()
    } catch (err) {
      this.error = err
    }
  }

  click() {
    this.btn.click()
  }

  onClick(callback) {
    this.btn.addEventListener("click", async (evt) => this.save(callback))
    return this // For chaining
  }
  onSave(callback) {
    this.btn.addEventListener("save-btn:save-start", async (evt) => await callback(evt))
    return this // For chaining
  }
  onSaveDone(callback) {
    this.btn.addEventListener("save-btn:save-success", async (evt) => await callback(evt))
    return this // For chaining
  }
  onError(callback) {
    this.btn.addEventListener("save-btn:error", async (evt) => await callback(evt))
    return this // For chaining
  }
}
