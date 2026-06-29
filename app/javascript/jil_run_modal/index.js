// Wires the function-task Run buttons on standalone pages (lists, whisper,
// trigger). Opens the shared modal for collecting args, then POSTs to the
// task's run endpoint.

import promptForArgs from "../jil/run_args_modal.js"
import { element } from "../jil/form_helpers.js"

function csrfToken() {
  return document.querySelector("meta[name=csrf-token]")?.content || ""
}

function buildFormBody(data) {
  const body = new URLSearchParams()
  body.append("authenticity_token", csrfToken())
  const walk = (prefix, value) => {
    if (Array.isArray(value)) {
      value.forEach((v) => walk(`${prefix}[]`, v))
    } else if (value !== null && typeof value === "object") {
      Object.entries(value).forEach(([k, v]) => walk(`${prefix}[${k}]`, v))
    } else if (value !== null && value !== undefined) {
      body.append(prefix, String(value))
    }
  }
  Object.entries(data).forEach(([k, v]) => walk(`data[${k}]`, v))
  return body
}

function flashTriggered(wrapper) {
  const messageWrapper = wrapper.querySelector(".message-wrapper")
  if (!messageWrapper) { return }
  wrapper.querySelectorAll(".execute-success-msg").forEach((n) => n.remove())
  const msg = element("span", { innerText: "Triggered!", class: "execute-success-msg" })
  messageWrapper.appendChild(msg)
  const prev = wrapper.dataset.msgTimeoutId
  if (prev) { clearTimeout(Number(prev)) }
  const id = setTimeout(() => msg.remove(), 1500)
  wrapper.dataset.msgTimeoutId = String(id)
}

async function openModalFor(wrapper) {
  const argsStr = wrapper.dataset.functionArgs
  const url = wrapper.dataset.runUrl
  const taskName = wrapper.dataset.taskName
  if (!argsStr || !url) { return }

  const data = await promptForArgs({ argsStr, taskName })
  if (data === null) { return }

  const res = await fetch(url, {
    method: "POST",
    headers: {
      "Accept": "application/json",
      "Content-Type": "application/x-www-form-urlencoded",
      "X-CSRF-Token": csrfToken(),
      "X-Requested-With": "XMLHttpRequest",
    },
    credentials: "same-origin",
    body: buildFormBody(data).toString(),
  }).catch((err) => {
    console.error("Run error:", err)
    return null
  })

  if (res && res.ok) {
    flashTriggered(wrapper)
  } else if (res) {
    console.error("Run failed:", res.status, res.statusText)
  }
}

document.addEventListener("click", (evt) => {
  const btn = evt.target.closest(".execute-btn")
  if (!btn) { return }
  const wrapper = btn.closest(".execute-btn-wrapper[data-function-args]")
  if (!wrapper) { return }

  evt.preventDefault()
  evt.stopPropagation()
  openModalFor(wrapper)
})
