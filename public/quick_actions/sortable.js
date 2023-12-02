import Sortable from "https://cdn.jsdelivr.net/npm/@shopify/draggable/build/esm/Sortable/Sortable.mjs"

const sortable = new Sortable(document.querySelectorAll(".widget-wrapper"), {
  draggable: ".widget-holder.jiggle",
})

let modes = ["use", "add", "move", "delete"]
let mode = 0

let templateContent = function(id, temp) {
  let template = temp || document.querySelector(id)
  let content = template.content.children

  return content.length == 1 ? content[0] : content
}

let randomHex = function(bytes=8) {
  // fill typed array with random numbers
  // from 0..255 per entry
  const array = new Uint8Array(bytes)
  window.crypto.getRandomValues(array)

  // wrap to array and convert numbers to hex
  // then join to single string
  return [...array].map(n => n.toString(16)).join("")
}

let replacePlaceholders = function(content, replacements) {
  for (var placeholder in replacements) {
    if (replacements.hasOwnProperty(placeholder)) {
      var regex = new RegExp(placeholder, "g");
      content = content.replace(regex, replacements[placeholder]);
    }
  }
  return content;
}

let addTemplateToWrapper = function(wrapper, data, template_id) {
  let template_content = templateContent(template_id)
  let temp = document.createElement("template")
  temp.innerHTML = replacePlaceholders(template_content.outerHTML, data)
  wrapper.append(templateContent(null, temp))
}

document.addEventListener("click", function(evt) {
  if (!evt.target.classList.contains("delete-widget")) { return }

  evt.preventDefault()
  evt.stopPropagation()
  evt.target.parentElement.remove()
  return false
})

document.addEventListener("click", function(evt) {
  let new_mode_name = evt.target.getAttribute("data-mode")
  if (!new_mode_name) { return }

  let new_mode = modes.indexOf(new_mode_name)
  if (mode == new_mode) {
    console.log("Toggle OFF!");
    new_mode = 0
    new_mode_name = modes[0]
  }
  mode = new_mode

  document.querySelectorAll(`[data-mode]`).forEach(item => {
    item.classList.remove("active")
    let item_mode = item.getAttribute("data-mode")
    let capital_mode = item_mode.charAt(0).toUpperCase() + item_mode.slice(1)
    item.text = capital_mode

    document.querySelectorAll(".jiggle").forEach(item => item.classList.remove("jiggle"))
    document.querySelectorAll(".delete-widget").forEach(item => item.classList.add("hidden"))
  })

  // TODO: Delete not working for specials (running their command)
  let body = document.querySelector("body")
  let mainWrapper = true
  let wrapper = document.querySelector(".modal.mini-widgets.show .widget-wrapper")
  if (wrapper) { mainWrapper = false }
  wrapper = wrapper || document.querySelector(".main-wrapper.widget-wrapper")

  if (new_mode_name == "add") {
    mode = 0
    let hex = randomHex(4)

    let title = prompt("Title")
    if (/\p{RGI_Emoji}/v.test(title)) {
      title = `<i class="emoji">${title}</i>`
    }
    if (mainWrapper) {
      let data = { "{{widget_name}}": title, "{{modal_id}}": `modal-${hex}` }
      addTemplateToWrapper(wrapper, data, "#template-main-widget")
      addTemplateToWrapper(body, data, "#template-modal")
    } else {
      let cmd = prompt("Command")
      let data = { "{{item_name}}": title, "{{item_command}}": cmd }
      addTemplateToWrapper(wrapper, data, "#template-mini-widget")
    }
    return
  } else if (new_mode_name == "move") {
    wrapper.querySelectorAll(".widget-holder").forEach(item => item.classList.add("jiggle"))
  } else if (new_mode_name == "delete") {
    wrapper.querySelectorAll(".delete-widget").forEach(item => item.classList.remove("hidden"))
  }

  document.querySelectorAll(`[data-mode="${new_mode_name}"]`).forEach(item => {
    evt.target.text = "Done"
  })
})

// .draggable-source--is-dragging // -- placeholder
// .draggable-mirror // -- held item (ghost)

// sortable.on("sortable:start", () => console.log("sortable:start"))
// sortable.on("sortable:sort", () => console.log("sortable:sort"))
// sortable.on("sortable:sorted", function(e) {
//   debugger
//   console.log("sortable:sorted")
// })
// sortable.on("sortable:stop", () => console.log("sortable:stop"))



// window.addEventListener("mousedown", function(e) {
//   if (e.button == 2) {
//     if (document.querySelector(".modal.show")) {
//       document.querySelectorAll(".modal.show .widget-holder").forEach((item) => {
//         item.classList.toggle("jiggle")
//       })
//     } else {
//       document.querySelectorAll(".widget-wrapper > .widget-holder").forEach((item) => {
//         item.classList.toggle("jiggle")
//       })
//     }
//   }
// })
