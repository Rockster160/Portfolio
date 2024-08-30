import Schema from "./schema.js"
import Tokenizer from "./tokenizer.js"
import sortable from "./sortable.js"

export function element(tag, data) {
  let ele = document.createElement(tag)
  if (data) {
    for (const [key, value] of Object.entries(data)) {
      if (key == "class") {
        ele.classList.add(...value.split(" "))
      } else if (key == "data") {
        for (const [dkey, dval] of Object.entries(data.data)) {
          ele.setAttribute(dkey, dval)
        }
      } else {
        ele[key] = value
      }
    }
  }
  return ele
}

export function field(arg) {
  if (!arg.typename) {
    if (arg.content) {
      let content = sortable(element("div", {
        class: "content",
        data: { allowed: arg.allowedtypes }
      }))
      let dropdown = element("div", { class: "content-dropdown below" })
      dropdown.appendChild(element("div", { class: "reference" }))
      if (arg.options) {
        dropdown.setAttribute("options", JSON.stringify(arg.options))
      }
      content.appendChild(dropdown)
      return content
    } else if (arg.options) {
      let wrapper = element("span", { class: "input-wrapper" })
      let ele = select(arg.options)
      wrapper.appendChild(ele)
      let dynamicWrapper = element("span", { class: "hidden dynamic input-wrapper" })
      let selectedTag = element("span", { class: "selected-tag" })
      dynamicWrapper.appendChild(element("btn", { innerText: "< String >", data: { inputtype: "String", allowInput: false } }))
      dynamicWrapper.appendChild(selectedTag)

      wrapper.insertBefore(dynamicWrapper, ele)
      wrapper.insertBefore(ele, dynamicWrapper)

      ele.addEventListener("change", (evt) => {
        if (ele.selectedOptions[0].value == "<dynamic>") {
          dynamicWrapper.classList.remove("hidden")
        } else {
          selectedTag.innerText = ""
          dynamicWrapper.classList.add("hidden")
        }
      })
      return wrapper
    } else {
      return element("span", { innerText: arg.raw })
    }
  }
  if (arg.typename == "BR") { return element("nl") }
  if (arg.typename == "TAB") { return element("tab") }

  let wrapper = element("span", { class: "input-wrapper" })
  let entryfield = inputFromArg(arg)
  let selectedTag = element("span", { class: "selected-tag" })
  if (entryfield.tagName == "TEXTAREA") {
    wrapper.appendChild(entryfield)
  } else if (arg.typename.match(/^Array\??$/)) {
    wrapper.appendChild(element("btn", { innerText: "< Array >", data: { inputtype: arg.typename, allowInput: false } }))
    wrapper.appendChild(selectedTag)
  } else if (arg.typename.match(/^Hash\??$/)) {
    wrapper.appendChild(element("btn", { innerText: "< Hash >", data: { inputtype: arg.typename, allowInput: false } }))
    wrapper.appendChild(selectedTag)
  } else {
    wrapper.appendChild(element("btn", { data: { inputtype: arg.typename } }))
    wrapper.appendChild(entryfield)
    wrapper.appendChild(selectedTag)
  }

  return wrapper
}

export function inputFromArg(arg) {
  let typename = arg.typename.indexOf("|") > 0 ? "String" : arg.preferredtype
  typename = typename == "Any" ? "Global" : typename
  let ele = inputFromType(typename)
  let type = Schema.types[typename]?.inputtype || "text"

  if (typeof arg.placeholder !== "undefined") { ele.placeholder = arg.placeholder }
  if (typeof arg.defaultval !== "undefined") {
    ele[type == "textarea" ? "innerText" : "value"] = arg.defaultval
  }
  if (!arg.optional) { ele.setAttribute("required", true) }

  return ele
}

export function inputFromType(typename) {
  let type = Schema.types[typename]?.inputtype || "text"

  let ele = element("input")
  if (type == "textarea") { ele = element("textarea") }
  if (type == "checkbox") { ele = slider() }

  if (type != "textarea") { ele.type = type }

  return ele
}

export function select(opts, data) {
  let ele = element("select", data)
  opts.forEach(item => {
    ele.appendChild(element("option", { name: item, value: item, innerText: item }))
  })
  ele.appendChild(element("option", { name: "<dynamic>", value: "<dynamic>", innerText: "<dynamic>" }))
  return ele
}

export function slider() {
  let ele = element("label", { class: "switch" })
  ele.appendChild(element("input", { type: "checkbox", value: false }))
  ele.appendChild(element("span", { class: "slider" }))

  return ele
}

export function clamp(number, min, max) {
  return Math.max(min, Math.min(number, max))
}

export function genLetter(count) {
  count = count || 1
  let randChar = () => String.fromCharCode(Math.floor(Math.random() * 26) + 97)
  return Array.from({ length: count }, randChar).join("")
}

export function genHex(count) {
  count = count || 1
  let randHex = () => Math.floor(Math.random() * 256).toString(16).padStart(2, "0")
  return Array.from({ length: count }, randHex).join("")
}

export function unwrap(str) {
  if (typeof str != "string") { return str }
  let trimmed = str.trim()
  let first = trimmed.charAt(0)
  let last = trimmed.charAt(trimmed.length-1)
  if (first != last) { return trimmed }
  if (first == "\"") { return trimmed.replaceAll(/^"|"$/g, "").trim() }
  if (first == "\'") { return trimmed.replaceAll(/^'|'$/g, "").trim() }
  return trimmed
}
