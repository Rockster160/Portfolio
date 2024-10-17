import SaveBtn from "./save_btn.js"
import Toast from "./toast.js"

export default function saveUtils() {
  // TODO:
  // If new task, and has value for either cron or listening:
  //   Show message saying it will not run until given a name and saved
  let jilTaskNameField = document.querySelector("#jil_task_name")
  let jilTaskForm = document.querySelector("#jil_task_form")
  let newTask = jilTaskForm.classList.contains("new_jil_task")

  // Initial code load
  if (newTask || window.load_code === undefined) {
    console.log(localStorage.getItem("jilcode"))
    Statement.reloadFromText(localStorage.getItem("jilcode"))
  } else {
    Statement.reloadFromText(window.load_code)
  }
  document.querySelector(".code-preview").innerText = Statement.toCode()

  let saveBtn = new SaveBtn(document.querySelector(".btn-save"))
  saveBtn.onClick(async () => {
    formSubmitting = true
    const code = Statement.toCode()
    document.querySelector(".code-preview").innerText = code
    if (newTask && jilTaskNameField.value.trim().length == 0) {
      localStorage.setItem("jilcode", code)
      return
    }

    const codeField = document.createElement("input")
    codeField.setAttribute("class", "jil-temp-code")
    codeField.setAttribute("type", "hidden")
    codeField.setAttribute("name", "jil_task[code]")
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
        if (newTask && json.url) {
          window.location.href = json.url
        }
      })
    })
  }).onError(async (evt) => {
    Toast.error(evt.detail || "[SAVE] Unknown Error")
    document.querySelector(".results .error").innerText = evt.detail || "[SAVE] Unknown Error"
  })

  let runBtn = new SaveBtn(document.querySelector(".btn-run"))
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
    Toast.error(evt.detail || "[Run] Unknown Error")
    document.querySelector(".results .error").innerText = evt.detail || "[RUN] Unknown Error"
  })

  window.onbeforeunload = function(evt) {
    if (formSubmitting || !formDirty) { return }

    return "You have unsaved changes. Are you sure you want to leave?"
  }
}
