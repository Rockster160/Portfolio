import SaveBtn from "./save_btn.js"

export default function saveUtils() {
  // TODO:
  // If new task, and has value for either cron or listening:
  //   Show message saying it will not run until given a name and saved
  let jilTaskNameField = document.querySelector("#jil_task_name")
  let jilTaskForm = document.querySelector("#jil_task_form")
  let newTask = jilTaskForm.classList.contains("new_jil_task")
  // let formSubmitting = false
  // let dirtyChanges = false

  // Initial code load
  if (newTask || window.load_code === undefined) {
    console.log(localStorage.getItem("jilcode"))
    Statement.reloadFromText(localStorage.getItem("jilcode"))
  } else {
    Statement.reloadFromText(window.load_code)
  }

  document.addEventListener("mousedown", function(event) {
    if (event.button === 1) {
      Statement.reloadFromText("")
    }
  });

  let saveBtn = new SaveBtn(document.querySelector(".btn-save"))
  saveBtn.onClick(async () => {
    // formSubmitting = true
    const code = Statement.toCode()
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
      document.querySelectorAll(".jil-temp-code").forEach(item => item.remove())
      if (!res.ok) { throw new Error(`HTTP error! status: ${res.status}`) }
      res.json().then(function(json) {
        if (newTask && json.url) {
          window.location.href = json.url
        }
      })
    })
  })

  let runBtn = new SaveBtn(document.querySelector(".btn-run"))
  runBtn.onClick(async () => {
    const code = Statement.toCode()

    await fetch(runBtn.btn.getAttribute("href"), {
      method: "POST",
      body: JSON.stringify({ code: code }),
      headers: { "Content-Type": "application/json", "Accept": "application/json" },
    }).then(function(res) {
      if (!res.ok) { throw new Error(`HTTP error! status: ${res.status}`) }
      // res.json().then(function(json) {
      //   console.log("Started")
      // })
    })
  })

  // window.onbeforeunload = function(evt) {
  //   if (formSubmitting || !dirtyChanges) { return }
  //
  //   return "You have unsaved changes. Are you sure you want to leave?"
  // }
}
