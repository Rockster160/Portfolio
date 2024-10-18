import Statement from "./statement"
import Rails from "@rails/ujs"
import consumer from "../src/channels/consumer"
Rails.start()

const jilTaskForm = document.querySelector("#task_form")
const taskUuid = document.querySelector("#task_uuid").value || "new"
const errorsDiv = document.querySelector(".results .error")
const resultsDiv = document.querySelector(".results .result")
const outputDiv = document.querySelector(".results .output")
const timestampSpan = document.querySelector(".results .timestamp")

const isBlank = (val) => {
  if (val === null || val === undefined) { return true }
  if (Array.isArray(val) && val.length == 0) { return true }
  if (typeof val === "string" && val.trim() === "") { return true }
  if (typeof val === "object" && Object.keys(val).length === 0) { return true }
  if (typeof val === "boolean") { return false } // explicitly not blank
  return false
}

const show = (val) => (typeof val === "string" || isBlank(val)) ? val : JSON.stringify(val)

consumer.subscriptions.create({
  channel: "TasksChannel", id: taskUuid,
},{
  received: function(data) {
    Statement.all.forEach(item => item.flash(false))
    if (data.line) {
      Statement.find(data.line).flash(true)
    }
    errorsDiv.innerText = show(data.error)
    resultsDiv.innerText = show(data.result)
    outputDiv.innerText = data.output?.join("\n")
    timestampSpan.innerText = data.timestamp
  }
})
