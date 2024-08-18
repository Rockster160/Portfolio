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
    this._saving = bool
    this.updateState()
  }

  get error() { return this._error }
  set error(msg) {
    this._saving = false
    this._error = msg
    this.updateState()
  }

  success() {
    this.saving = false
    let originalColor = window.getComputedStyle(this.btn).backgroundColor;
    this.btn.style.transition = "background-color 0s";
    this.btn.classList.add("btn-flash")

    setTimeout(() => {
      this.btn.style.transition = "background-color 2s";
      this.btn.classList.remove("btn-flash")

    }, 100);
    this.flashTimer = setTimeout(() => {
      this.btn.style.transition = "background-color 0s";
    }, 2000);
  }

  updateState() {
    clearTimeout(this.flashTimer)
    this.btn.style.transition = "background-color 0s";
    this.btn.classList.remove("btn-flash")

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

  onClick(callback) {
    this.btn.addEventListener("click", async (evt) => this.save(callback))
  }
}
