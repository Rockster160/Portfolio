import Statement from "./statement"
import Rails from "@rails/ujs"
import consumer from "../src/channels/consumer"
Rails.start()

const jilTaskForm = document.querySelector("#jil_task_form")
const taskUuid = document.querySelector("#jil_task_uuid").value || "new"
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
    resultsDiv.innerText = data.result
    ouputDiv.innerText = data.output?.join("\n")
  }
})
