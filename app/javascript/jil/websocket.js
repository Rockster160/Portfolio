import Statement from "./statement"
import Rails from "@rails/ujs"
import consumer from "../src/channels/consumer"
Rails.start()

const jilTaskForm = document.querySelector("#jil_task_form")
const taskUuid = document.querySelector("#jil_task_uuid").value || "new"
const errorsDiv = document.querySelector(".results .error")
const resultsDiv = document.querySelector(".results .result")
const ouputDiv = document.querySelector(".results .output")

consumer.subscriptions.create({
  channel: "JilTasksChannel", id: taskUuid,
},{
  received: function(data) {
    Statement.all.forEach(item => item.flash(false))
    if (data.line) {
      Statement.find(data.line).flash(true)
    }
    errorsDiv.innerText = data.error
    resultsDiv.innerText = data.result
    ouputDiv.innerText = data.output?.replace("\\n", "\n")?.join("\n")
  }
})
