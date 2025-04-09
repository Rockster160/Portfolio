import SaveBtn from "./save_btn.js"
import Toast from "./toast.js"

window.onbeforeunload = function(evt) {
  if (formSubmitting || !formDirty) { return } // window vars

  return "You have unsaved changes. Are you sure you want to leave?"
}

export const jilTaskForm = document.querySelector("#task_form")
export const jilTaskNameField = document.querySelector("#task_name")
export const isNewTask = jilTaskForm.classList.contains("new_task")

// TODO:
// When new task, and entered value for either cron or listening:
//   Show message saying it will not run until given a name and saved
export function setup() {
  // Add the `formDirty` getter/setter to window that has a magic callback
  Object.defineProperty(window, "formDirty", {
    get() {
      return window._formDirty;
    },
    set(value) {
      document.querySelector(".btn-save").classList.toggle("btn-dirty", value)
      window._formDirty = value;
    }
  })
  // Load code from text or local storage
  if (isNewTask || window.load_code === undefined) {
    console.log(localStorage.getItem("jilcode"))
    Statement.reloadFromText(localStorage.getItem("jilcode"))
  } else {
    Statement.reloadFromText(window.load_code)
  }
  // Set up `record` as a helper to collect the necessary data without always passing it
  History.record = function() {
    if (History.add({ settings: formJson(), code: Statement.toCode() })) {
      formDirty = !History.noChange()
      console.log("Recorded: ", History.currentIdx)
      document.querySelector(".code-preview").innerHTML = Statement.toCode(true)
    }
  }

  History.record() // Store initial state in history
  formDirty = false // Initial load should not dirty the state
}

export function formJson() {
  const formData = new FormData(jilTaskForm);
  const data = {};

  formData.forEach((value, key) => {
    if (key == "authenticity_token") { return }
    if (key == "_method") { return }
    data[key] = value;
  });

  return data
}
export function setFormJson(json) {
  Object.entries(json).forEach(([key, value]) => {
    const field = jilTaskForm.querySelector(`[name="${key}"]`);
    // debugger
    if (field) {
      field.value = value;
    }
  })
}

export function run() {
  runBtn.click()
}
export function save() {
  saveBtn.click()
}
export function undo() {
  const { settings, code } = History.undo()
  if (code === undefined || code === null) { return }
  console.log("Undo", History.savedIdx, History.currentIdx)

  setFormJson(settings)
  Statement.reloadFromText(code)
  formDirty = !History.noChange()
}
export function redo() {
  const { settings, code } = History.redo()
  if (code === undefined || code === null) { return }
  console.log("Redo", History.savedIdx, History.currentIdx)

  setFormJson(settings)
  Statement.reloadFromText(code)
  formDirty = !History.noChange()
}

export const saveBtn = new SaveBtn(document.querySelector(".btn-save"))
saveBtn.onClick(async () => {
  formSubmitting = true
  const code = Statement.toCode()
  if (isNewTask && jilTaskNameField.value.trim().length == 0) {
    localStorage.setItem("jilcode", code)
    return
  }

  const codeField = document.createElement("input")
  codeField.setAttribute("class", "jil-temp-code")
  codeField.setAttribute("type", "hidden")
  codeField.setAttribute("name", "task[code]")
  codeField.setAttribute("value", code)
  jilTaskForm.appendChild(codeField)

  let formData = new FormData(jilTaskForm)

  await fetch(jilTaskForm.getAttribute("action"), {
    method: jilTaskForm.querySelector("[name=_method]")?.value?.toUpperCase() || jilTaskForm.getAttribute("method"),
    body: formData,
    headers: { "Accept": "application/json" },
  }).then(function(res) {
    formSubmitting = false
    formDirty = false
    History.savedIdx = History.currentIdx
    document.querySelectorAll(".jil-temp-code").forEach(item => item.remove())
    if (!res.ok) { throw new Error(`HTTP error! status: ${res.status} response: ${JSON.stringify(res)}`) }
    res.json().then(function(json) {
      const toastMessage = document.createElement("span")
      toastMessage.classList.add("fa", "fa-check", "text-center")
      Toast.success(toastMessage, 2000)
      if (isNewTask && json.url) {
        window.location.href = json.url
      }
    })
  })
}).onError(async (evt) => {
  Toast.error((evt.detail && JSON.stringify(evt.detail)) || "[SAVE] Unknown Error")
  document.querySelector(".results .error").innerText = evt.detail || "[SAVE] Unknown Error"
})

export const runBtn = new SaveBtn(document.querySelector(".btn-run"))
runBtn.onClick(async () => {
  const code = Statement.toCode()

  await fetch(runBtn.btn.getAttribute("href"), {
    method: "POST",
    body: JSON.stringify({ code: code }),
    headers: { "Content-Type": "application/json", "Accept": "application/json" },
  }).then(function(res) {
    if (!res.ok) { throw new Error(`HTTP error! status: ${res.status} response: ${JSON.stringify(res)}`) }
    // res.json().then(function(json) {
    //   console.log("Started")
    // })
  })
}).onError(async (evt) => {
  Toast.error((evt.detail && JSON.stringify(evt.detail)) || "[Run] Unknown Error")
  document.querySelector(".results .error").innerText = evt.detail || "[RUN] Unknown Error"
})

const enabledCheckbox = document.querySelector("input[name='task[enabled]'][type=checkbox]")
function setEnabled() {
  document.querySelector(".disabled-label").classList.toggle("hidden", enabledCheckbox.checked)
}
enabledCheckbox.addEventListener("change", setEnabled)
setEnabled() // Set initial state

jilTaskNameField.addEventListener("change", () => {
  document.querySelector(".task-name").innerText = jilTaskNameField.value
})
