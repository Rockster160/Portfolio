// Shared modal for prompting the user for the args to a function-listener task.
// Used by both the editor's Run button (save_utils.js) and the standalone
// trigger pages (jil_run_modal entry).

import Schema from "./schema.js"
import Method from "./method.js"
import { field, element, unwrap } from "./form_helpers.js"
import { bindingFor, collectValues } from "./arg_binding.js"

function ensureSchemaLoaded() {
  if (Schema.all.length <= 4 && window.load_schema) {
    Schema.load(window.load_schema)
  }
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
    const declaredLabel = pendingLabel
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
    // A QUOTED LABEL makes the arg addressable by name as well as by position.
    //
    // Buddy already posts these under lowercase_snake_case of the label (see
    // call_jil_function), so `"When" TAB String` arrives as `when` from a Buddy
    // call and as nothing at all from here — a task written with
    // `Keyword.NamedArg("when")` read blank every time somebody hit Run in the
    // editor, which is the only reason those tasks were written positionally.
    //
    // Positional reads are why that matters: `params` is built from the keys the
    // caller actually SENT, so one omitted middle arg shifts every arg after it
    // onto the wrong name. Being able to ask for an arg by its own label is what
    // makes an optional arg safe to put anywhere but last.
    //
    // Purely additive — collectValues still pushes every field into `params` in
    // declaration order, so tasks reading positionally are untouched.
    fields.push({ ...bindingFor(declaredLabel), node })
  })

  return fields
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
