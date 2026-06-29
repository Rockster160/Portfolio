// Shared modal for prompting the user for the args to a function-listener task.
// Used by both the editor's Run button (save_utils.js) and the standalone
// trigger pages (jil_run_modal entry).

import Schema from "./schema.js"
import Method from "./method.js"
import { field, element, unwrap } from "./form_helpers.js"

function ensureSchemaLoaded() {
  if (Schema.all.length <= 4 && window.load_schema) {
    Schema.load(window.load_schema)
  }
}

function readInputValue(input) {
  if (!input) { return null }
  switch (input.type) {
    case "checkbox": return input.checked
    case "number":
      if (input.value === "") { return null }
      return parseFloat(input.value)
    default:
      return input.dataset.raw || input.value
  }
}

function findInput(wrapper) {
  if (!wrapper) { return null }
  return wrapper.querySelector(":scope > input, :scope > textarea, :scope > select, :scope > .switch > input")
}

function selectFrom(optionsStr, defaultval) {
  const ele = element("select")
  const matches = String(optionsStr).match(/"[^"]*"|[^\s\[\]]+/g) || []
  matches.forEach((raw) => {
    const val = unwrap(raw)
    const opt = element("option", { value: val, innerText: val })
    if (defaultval !== undefined && defaultval !== null && unwrap(String(defaultval)) === val) {
      opt.selected = true
    }
    ele.appendChild(opt)
  })
  return ele
}

// Render a single labeled input for a named option (e.g. from a content block).
function inputFromOpt(opt) {
  const wrapper = element("span", { class: "input-wrapper" })

  if (opt.selectArgs) {
    wrapper.appendChild(selectFrom(opt.selectArgs, opt.defaultval))
    return wrapper
  }

  const inputtype = Schema.types[opt.type]?.inputtype || "text"
  let ele
  if (inputtype === "textarea") {
    ele = element("textarea")
  } else if (inputtype === "checkbox") {
    ele = element("input")
    ele.type = "checkbox"
    if (opt.defaultval !== undefined && opt.defaultval !== null) {
      ele.checked = String(opt.defaultval) === "true"
    }
  } else {
    ele = element("input")
    ele.type = inputtype === "password" ? "text" : inputtype
  }
  if (opt.defaultval !== undefined && opt.defaultval !== null && ele.type !== "checkbox") {
    ele.value = unwrap(String(opt.defaultval))
  }
  ele.placeholder = opt.type
  wrapper.appendChild(ele)
  return wrapper
}

function rowFor(labelText, fieldEl) {
  const wrapper = element("div", { class: "run-modal-row" })
  if (labelText) {
    const label = element("label", { class: "run-modal-label", innerText: labelText })
    wrapper.appendChild(label)
  }
  fieldEl.classList?.add("run-modal-field")
  wrapper.appendChild(fieldEl)
  return wrapper
}

function renderArgs(container, argsStr) {
  ensureSchemaLoaded()

  const args = Method.splitToArgs(argsStr)
  const fields = []
  let pendingLabel = null
  let positionalIdx = 0

  args.forEach((arg) => {
    if (arg.typename === "BR" || arg.typename === "TAB") { return }

    if (arg.raw && !arg.typename) {
      pendingLabel = arg.raw
      return
    }

    if (arg.content && arg.options) {
      arg.options.forEach((opt) => {
        if (typeof opt !== "object" || !opt.name) { return }
        const node = inputFromOpt(opt)
        container.appendChild(rowFor(opt.name, node))
        fields.push({ kind: "named", name: opt.name, node })
      })
      return
    }

    const node = field(arg)
    if (!node) { return }

    // `[opt1 opt2]:Name` → use Name as the arg label and bind it as a named arg.
    const enumNamed = arg.str?.match(/^\s*\[.*\]\s*:\s*([A-Za-z_]\w*)\s*$/)
    let label = pendingLabel
    pendingLabel = null
    if (enumNamed) {
      label = enumNamed[1]
      container.appendChild(rowFor(label, node))
      fields.push({ kind: "named", name: enumNamed[1], node })
      return
    }
    positionalIdx += 1
    if (!label) { label = arg.preferredtype || `arg ${positionalIdx}` }

    container.appendChild(rowFor(label, node))
    fields.push({ kind: "positional", node })
  })

  return fields
}

// Build the input_data hash. Every value also goes into `params` (in declaration
// order) so the task can read it via positional `Global.functionParams` /
// `Global.params()` regardless of whether the listener spelled the arg with a
// name. Named args additionally appear at the top level under their name.
function collectValues(fields) {
  const data = {}
  const params = []
  fields.forEach((f) => {
    const value = readInputValue(findInput(f.node))
    if (f.kind === "named") { data[f.name] = value }
    params.push(value)
  })
  if (params.length > 0) { data.params = params }
  return data
}

// Open a modal and resolve with the collected data when the user submits.
// Resolves with null if the user dismisses the modal.
//
// promptForArgs({ argsStr, taskName }) → Promise<Object|null>
export default function promptForArgs({ argsStr, taskName }) {
  return new Promise((resolve) => {
    const overlay = element("div", { class: "run-task-modal-overlay" })
    overlay.tabIndex = -1

    const card = element("div", { class: "run-task-modal-card" })
    const titleBar = element("div", { class: "run-task-modal-title", innerText: taskName || "Run task" })
    const close = element("a", { class: "run-task-modal-close", href: "#" })
    close.innerHTML = '<i class="fa fa-times-circle-o fa-2x"></i>'
    const dismiss = () => { overlay.remove(); resolve(null) }
    close.addEventListener("click", (e) => { e.preventDefault(); dismiss() })
    titleBar.appendChild(close)

    const argsContainer = element("div", { class: "run-task-args" })
    const fields = renderArgs(argsContainer, argsStr)

    const submit = element("button", { class: "btn run-task-submit", innerText: "Run" })
    submit.type = "button"

    card.appendChild(titleBar)
    card.appendChild(argsContainer)
    card.appendChild(submit)
    overlay.appendChild(card)
    document.body.appendChild(overlay)

    overlay.addEventListener("click", (e) => {
      if (e.target === overlay) { dismiss() }
    })

    submit.addEventListener("click", () => {
      const data = collectValues(fields)
      overlay.remove()
      resolve(data)
    })

    argsContainer.querySelector("input, textarea, select")?.focus()
  })
}
