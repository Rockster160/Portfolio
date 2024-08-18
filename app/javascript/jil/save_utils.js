import SaveBtn from "./save_btn.js"

export default function saveUtils() {
  // TODO:
  // If new task, and has value for either cron or listening:
  //   Show message saying it will not run until given a name and saved
  let jilTaskNameField = document.querySelector("#jil_task_name")
  // let formSubmitting = false
  // let dirtyChanges = false
  let jilTaskForm = document.querySelector("#jil_task_form")
  let newTask = jilTaskForm.classList.contains("new_jil_task")

  // Initial code load
  if (newTask || window.load_code === undefined) {
    Statement.reloadFromText(localStorage.getItem("jilcode"))
  } else {
    Statement.reloadFromText(window.load_code)
  }

  let saveBtn = new SaveBtn(document.querySelector(".btn-save"))
  saveBtn.onClick(async () => {
    const code = Statement.toCode()
    if (newTask && jilTaskNameField.value.trim().length == 0) {
      localStorage.setItem("jilcode", code)
      return
    }

    // formSubmitting = true

    const codeField = document.createElement("input")
    codeField.setAttribute("type", "hidden")
    codeField.setAttribute("name", "jil_task[code]")
    codeField.setAttribute("value", code)
    jilTaskForm.appendChild(codeField)

    let formData = new FormData(jilTaskForm)
    // let body = new FormData(jilTaskForm)
    // let json = Object.fromEntries(body)
    // json["jil_tasks[code]"] = code

    await fetch(jilTaskForm.getAttribute("action"), {
      method: jilTaskForm.querySelector("[name=_method]")?.value?.toUpperCase() || jilTaskForm.getAttribute("method"),
      body: formData,
      headers: { "Accept": "application/json" },
    }).then(function(res) {
      if (!res.ok) { throw new Error(`HTTP error! status: ${res.status}`) }
      res.json().then(function(json) {
        if (newTask && json.url) {
          window.location.href = json.url
        }
      })
    })
  })

  // window.onbeforeunload = function(evt) {
  //   if (formSubmitting || !dirtyChanges) { return }
  //
  //   return "You have unsaved changes. Are you sure you want to leave?"
  // }
}
