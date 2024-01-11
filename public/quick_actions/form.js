import { Monitor } from './task_monitor.js';
import { command } from './command.js';
import { showModal, hideModal } from './modal.js';

let modes = ["use", "add", "edit", "move", "delete"]
let mode = 0
let currentWidget = null

export let templateContent = function(id, temp) {
  let template = temp || document.querySelector(id)
  let content = template.content.children

  return content.length == 1 ? content[0] : content
}

export let htmlToNode = function(html) {
  let temp = document.createElement("template")
  temp.innerHTML = html
  return templateContent(null, temp)
}

let attr = (attrKey) => currentWidget?.getAttribute(`data-${attrKey}`) || ""
let showForm = function(widget) {
  currentWidget = widget?.closest(".widget-holder")?.querySelector(".widget")

  let form = document.querySelector(".widget-form")
  // Clear all fields
  form.querySelectorAll("input[type='text']").forEach(item => item.value = "")
  // Reset checkboxes
  form.querySelectorAll("input[type='checkbox']").forEach(item => item.checked = true)
  // Reset "select" and trigger event to display correct fields
  form.querySelector("select#widget-type").value = attr("type")
  form.querySelector("select#widget-type").dispatchEvent(new Event("change"))

  if (currentWidget) {
    for (const [key, value] of Object.entries(currentWidget.dataset)) {
      let hyphen = key.replace(/([a-z])([A-Z])/g, "$1-$2").toLowerCase()
      // Set [type=text] values
      let input = form.querySelector(`input[type='text']#${hyphen}`)
      if (input) { input.value = value }

      // Set [type=checkbox] values
      let checkbox = form.querySelector(`input[type='checkbox']#${hyphen}`)
      if (checkbox) { checkbox.checked = value == "true" }
    }

    form.querySelector("input[type='submit']").value = "Update"
  } else {
    form.querySelector("input[type='submit']").value = "Add"
  }

  showModal("widget-form")
}

let submitWidgetForm = function(formdata) {
  let body = document.querySelector("body")
  let wrapper = document.querySelector(".widget-modal.show .widget-wrapper")
  wrapper = wrapper || document.querySelector(".main-wrapper.widget-wrapper")

  let url = document.querySelector(".main-wrapper").getAttribute("data-widget-url")
  let param_str = Object.keys(formdata)
    .map(key => encodeURIComponent(key) + "=" + encodeURIComponent(formdata[key]))
    .join("&");

  fetch(url + "?" + param_str, {
    method: "GET",
  }).then(function(res) {
    res.json().then(function(json) {
      if (res.ok) {
        if (currentWidget) {
          if (json.modal) {
            let modalId = currentWidget.closest(".widget-holder").getAttribute("data-modal")
            document.querySelector(`.modal#${modalId}`).remove()
          }
          currentWidget.closest(".widget-holder").outerHTML = json.html
        } else {
          wrapper.append(htmlToNode(json.html))
        }
        if (json.modal) {
          document.querySelector(".modal").after(htmlToNode(json.modal))
        }
        hideModal("widget-form")
        saveFullWidgets()
        currentWidget = null
        setTimeout(function() { Monitor.resyncAll() }, 500)
      }
    })
  })
}

let compactHash = function(hash) {
  return Object.fromEntries(Object.entries(hash).filter(([_, value]) => value))
}

document.addEventListener("submit", function(evt) {
  let form = evt.target
  if (form.classList.contains("widget-form")) {
    evt.preventDefault()

    let formData = Object.fromEntries(new FormData(form).entries())
    submitWidgetForm(formData)

    return false
  }
})

document.addEventListener("click", function(evt) {
  if (evt.target.matches(".delete-widget")) {
    let holder = evt.target.closest(".widget-holder")
    let modalId = holder.getAttribute("data-modal")

    document.querySelector(`.modal#${modalId}`).remove()
    holder.remove()
  }
  if (evt.target.matches(".edit-widget")) {
    showForm(evt.target)
  }
})

document.addEventListener("click", function(evt) {
  let mode_name = evt.target.getAttribute("data-mode")
  if (!mode_name) { return }

  // Reset buttons to original state and stop jiggle/delete states
  document.querySelectorAll("[data-mode]").forEach(item => {
    item.classList.remove("active")
    let item_mode = item.getAttribute("data-mode")
    let capital_mode = item_mode.charAt(0).toUpperCase() + item_mode.slice(1)
    item.text = capital_mode

    document.querySelectorAll(".jiggle").forEach(item => item.classList.remove("jiggle"))
    document.querySelectorAll(".delete-widget").forEach(item => item.classList.add("hidden"))
    document.querySelectorAll(".edit-widget").forEach(item => item.classList.add("hidden"))
  })

  let new_mode = modes.indexOf(mode_name)
  if (mode == new_mode) {
    // Reset mode to default state since the currently active one was clicked again
    mode = 0
    mode_name = modes[0]
    saveFullWidgets() // Save changes
  } else {
    mode = new_mode
  }

  // TODO: Delete not working for specials (running their command)
  let body = document.querySelector("body")
  let mainWrapper = true
  let wrapper = document.querySelector(".widget-modal.show .widget-wrapper")
  if (wrapper) { mainWrapper = false }
  wrapper = wrapper || document.querySelector(".main-wrapper.widget-wrapper")

  if (mode_name == "add") {
    showForm()
    if (mainWrapper) {
      document.querySelector("select#widget-type").value = "buttons"
    } else {
      document.querySelector("select#widget-type").value = "command"
    }
    document.querySelector("select#widget-type").dispatchEvent(new Event("change"))

    mode = 0
    return
  } else if (mode_name == "move") {
    wrapper.querySelectorAll(".widget-holder").forEach(item => item.classList.add("jiggle"))
  } else if (mode_name == "delete") {
    wrapper.querySelectorAll(".delete-widget").forEach(item => item.classList.remove("hidden"))
  } else if (mode_name == "edit") {
    wrapper.querySelectorAll(".edit-widget").forEach(item => item.classList.remove("hidden"))
  }

  document.querySelectorAll(`[data-mode="${mode_name}"]`).forEach(item => {
    evt.target.text = "Done"
  })
})

let collectWidgetData = function(widget) {
  let widget_data = {}
  Array.from(widget.attributes).forEach(attr => {
    if (attr.name.startsWith("data-")) {
      widget_data[attr.name.replace("data-", "")] = attr.value
    }
  })
  if (widget_data.type == "buttons") {
    widget_data.buttons = gatherButtons(widget)
  }

  return compactHash(widget_data)
}

let gatherButtons = function(widget) {
  let modal_id = widget.parentElement.getAttribute("data-modal")
  if (!modal_id) { return [] }

  return Array.from(document.querySelectorAll(`#${modal_id} .widget`)).map(item => {
    return collectWidgetData(item)
  })
}

let gatherWidgets = function() {
  let widgets = document.querySelectorAll(".main-wrapper > .widget-holder > .widget")
  return Array.from(widgets).map(widget => {
    return collectWidgetData(widget)
  })
}

let saveFullWidgets = function() {
  Monitor.updateStatus()
  command.refreshStatus()

  let url = document.querySelector(".main-wrapper").getAttribute("data-update-url")
  fetch(url, {
    method: "PATCH",
    body: JSON.stringify({ blocks: gatherWidgets() }),
    headers: {
      "Content-type": "application/json; charset=UTF-8"
    }
  }).then(function(res) {
    if (res.ok) {
    }
  })
}
