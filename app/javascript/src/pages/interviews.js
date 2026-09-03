// Interview tracker — /interviews.
//
// Three small jobs, none of which the page depends on: the capture form's
// new-company fieldset, the status dropdown submitting itself, and the logo
// square. Every one has a working no-JS path behind it (the fieldset is simply
// visible, the status form keeps its submit button, and a job with no logo
// shows its initials), so a failure here degrades rather than breaks.
import { bindIconStack } from "../icon_stack";

$(document).ready(function () {
  const page = document.querySelector("[data-interviews]")
  if (!page) { return }

  const csrfToken = function () {
    return document.querySelector("meta[name=csrf-token]")?.content || ""
  }

  // ---- Capture form ------------------------------------------------------
  // "Pick a job, or name a new one." The controller decides which happened, so
  // all this does is stop showing the new-company fields for a company you
  // already have — and mark the name required only when it actually is.
  const picker = page.querySelector("[data-capture-picker]")
  const newFields = page.querySelector("[data-capture-new]")
  const companyInput = page.querySelector("[data-capture-company]")

  if (picker && newFields) {
    const syncCapture = function () {
      const creating = !picker.value
      newFields.classList.toggle("hidden", !creating)
      if (companyInput) { companyInput.required = creating }
    }

    picker.addEventListener("change", syncCapture)
    syncCapture()
  }

  // ---- Status ------------------------------------------------------------
  const statusSelect = page.querySelector("[data-status-select]")
  const statusSubmit = page.querySelector("[data-status-submit]")
  if (statusSelect && statusSubmit) {
    statusSubmit.classList.add("hidden")
    statusSelect.addEventListener("change", function () {
      statusSelect.form.submit()
    })
  }

  // ---- Logo --------------------------------------------------------------
  // The square handles emoji, a paste, a drop and the shared picker modal on
  // its own. The only shape it hands back here is an IMAGE, because what gets
  // stored has to be a small square rather than whatever came off the
  // clipboard — that goes through the cropper below and returns as a 128px
  // WebP data URL, exactly what a household icon is.
  const OUTPUT_SIZE = 128

  const wireLogoControl = function (scope) {
    const stack = scope.querySelector("[data-icon-stack]")
    const panel = scope.querySelector("[data-logo-panel]")
    if (!stack || !panel) { return }

    const patchUrl = scope.dataset.logoUrl || null

    const drop = panel.querySelector("[data-logo-drop]")
    const stage = panel.querySelector("[data-logo-stage]")
    const canvas = panel.querySelector("[data-logo-canvas]")
    const zoom = panel.querySelector("[data-logo-zoom]")
    const fileBtn = panel.querySelector("[data-logo-file-btn]")
    const fileInput = panel.querySelector("[data-logo-file]")
    const urlInput = panel.querySelector("[data-logo-url-input]")
    const errorEl = panel.querySelector("[data-logo-error]")
    const saveBtn = panel.querySelector("[data-logo-save]")
    const cancelBtn = panel.querySelector("[data-logo-cancel]")

    const ctx = canvas.getContext("2d")
    const state = { image: null, scale: 1, x: 0, y: 0, dragging: false, lastX: 0, lastY: 0 }

    const showError = function (message) {
      errorEl.textContent = message
      errorEl.classList.toggle("hidden", !message)
    }

    const draw = function () {
      ctx.clearRect(0, 0, canvas.width, canvas.height)
      if (!state.image) { return }

      ctx.drawImage(
        state.image, state.x, state.y,
        state.image.width * state.scale, state.image.height * state.scale
      )
    }

    // Start with the image covering the square — the crop everyone wants nine
    // times in ten — and centred, so the zoom slider and the drag are both
    // adjustments rather than the only way to see anything.
    const loadImage = function (src) {
      const img = new Image()
      img.crossOrigin = "anonymous"
      img.onload = function () {
        state.image = img
        const cover = Math.max(canvas.width / img.width, canvas.height / img.height)
        state.scale = cover
        state.x = (canvas.width - img.width * cover) / 2
        state.y = (canvas.height - img.height * cover) / 2
        zoom.min = (cover / 4).toFixed(3)
        zoom.max = (cover * 4).toFixed(3)
        zoom.step = (cover / 100).toFixed(4)
        zoom.value = cover
        stage.classList.remove("hidden")
        saveBtn.disabled = false
        showError("")
        draw()
      }
      img.onerror = function () { showError("Couldn't load that image.") }
      img.src = src
    }

    const loadFile = function (file) {
      if (!file || !file.type.startsWith("image/")) {
        return showError("That doesn't look like an image.")
      }

      const reader = new FileReader()
      reader.onload = function (e) { loadImage(e.target.result) }
      reader.onerror = function () { showError("Couldn't read that file.") }
      reader.readAsDataURL(file)
    }

    const open = function (source) {
      panel.classList.remove("hidden")
      showError("")
      if (source instanceof File) { loadFile(source) }
      else if (typeof source === "string" && source) { loadImage(source) }
    }

    // WebP first, PNG where it isn't supported. `toDataURL` silently hands
    // back a PNG when it doesn't know the type, so the check is on what came
    // out rather than on what was asked for.
    const encode = function () {
      const out = document.createElement("canvas")
      out.width = OUTPUT_SIZE
      out.height = OUTPUT_SIZE
      const octx = out.getContext("2d")
      const ratio = OUTPUT_SIZE / canvas.width
      octx.drawImage(
        state.image, state.x * ratio, state.y * ratio,
        state.image.width * state.scale * ratio, state.image.height * state.scale * ratio
      )

      const webp = out.toDataURL("image/webp", 0.9)
      return webp.startsWith("data:image/webp") ? webp : out.toDataURL("image/png")
    }

    // An image detours through the cropper; everything else the square already
    // handled and never reaches here.
    bindIconStack(stack, { onImage: open })

    // One way in and out. Whatever set the value — typing, a pick, a paste, a
    // finished crop — arrives as this event, so there is a single place that
    // knows how to persist and it can't disagree with itself.
    let saveTimer = null
    stack.addEventListener("icon-stack-change", function (e) {
      if (!patchUrl) { return }

      clearTimeout(saveTimer)
      saveTimer = setTimeout(function () { persist(e.detail.value) }, 400)
    })

    const persist = function (value) {
      fetch(patchUrl, {
        method:      "PATCH",
        headers:     { "Content-Type": "application/json", "Accept": "application/json", "X-CSRF-Token": csrfToken() },
        credentials: "same-origin",
        body:        JSON.stringify({ job_application: { logo: value } }),
      }).then(function (response) {
        if (!response.ok) { throw new Error("save failed") }
        showError("")
      }).catch(function () {
        showError("Couldn't save that logo.")
        panel.classList.remove("hidden")
      })
    }

    saveBtn.addEventListener("click", function (e) {
      e.preventDefault()
      if (!state.image) { return }

      stack.__setIconValue(encode())
      panel.classList.add("hidden")
    })

    cancelBtn.addEventListener("click", function () { panel.classList.add("hidden") })

    fileBtn.addEventListener("click", function () { fileInput.click() })
    fileInput.addEventListener("change", function () { loadFile(fileInput.files[0]) })

    urlInput.addEventListener("change", function () {
      if (urlInput.value.trim()) { loadImage(urlInput.value.trim()) }
    })

    drop.addEventListener("dragover", function (e) {
      e.preventDefault()
      drop.classList.add("is-over")
    })
    drop.addEventListener("dragleave", function () { drop.classList.remove("is-over") })
    drop.addEventListener("drop", function (e) {
      e.preventDefault()
      drop.classList.remove("is-over")
      loadFile(e.dataTransfer.files[0])
    })

    zoom.addEventListener("input", function () {
      if (!state.image) { return }

      // Zoom about the middle of the square rather than the top-left corner,
      // which is where a logo walks off the canvas as soon as you drag the
      // slider.
      const next = parseFloat(zoom.value)
      const mid = canvas.width / 2
      state.x = mid - ((mid - state.x) / state.scale) * next
      state.y = mid - ((mid - state.y) / state.scale) * next
      state.scale = next
      draw()
    })

    canvas.addEventListener("pointerdown", function (e) {
      if (!state.image) { return }

      state.dragging = true
      state.lastX = e.clientX
      state.lastY = e.clientY
      canvas.setPointerCapture(e.pointerId)
    })

    canvas.addEventListener("pointermove", function (e) {
      if (!state.dragging) { return }

      state.x += e.clientX - state.lastX
      state.y += e.clientY - state.lastY
      state.lastX = e.clientX
      state.lastY = e.clientY
      draw()
    })

    const endDrag = function () { state.dragging = false }
    canvas.addEventListener("pointerup", endDrag)
    canvas.addEventListener("pointercancel", endDrag)
  }

  page.querySelectorAll("[data-logo-scope]").forEach(wireLogoControl)
})
