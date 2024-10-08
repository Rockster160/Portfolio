import { fa, faStack } from "./icon.js"
import { element, unwrap, field } from "./form_helpers.js"
import Statement from "./statement.js"
import Arg from "./arg.js"
import Dropdown from "./dropdown.js"
import sortable from "./sortable.js"
import Schema from "./schema.js"
import History from "./history.js"
import Mouse from "./mouse.js"
import Keyboard from "./keyboard.js"
import saveUtils from "./save_utils.js"

window.Schema = Schema
window.Statement = Statement
window.History = History
window.selected = undefined
window.formSubmitting = false

export const record = function() {
  History.add(Statement.toCode())
  console.log("Recorded: ", History.currentIdx)
}

saveUtils()
record() // Store initial state in history

// BUG:
//
// TODO:
// Select + Delete/Backspace should remove the statement
// Should be able to click on delete while a statement is commented
// Need some way to define custom functions/classes
//   * Require this be a different file?
//     * Nahhhhhh. Inline functions would be really nice and convenient...
//     * Inline classes, too.
//   * "Import" should essentially just run the code from the given file, giving access to functions/classes (and overwriting any existing methods based on the most recent definition)
//   * Difference between "import" and "run"? Maybe "import" does some magic and only pulls function/class definitions but doesn't do any logic...
//     * This would break if any definitions are nested in logic?
//   Maybe definitions can ONLY be done on the top level? Definitions should also pre-run so they can be defined at the end of the file but used at the top?
// Maybe? If there are no args in a Task, flatten it to take up less room
// * Should probably redesign the chevrons to not look like items
// On Dropdowns with a < type > - Need to have an empty state
// Dropdown should have 2|3 columns: Global|Scoped?|Tokens
// * Scoped would be contextual methods: Index, Object, Key, Value, etc
// Statement.fromText(localStorage.getItem("jilcode"))

Keyboard.on(["Meta", "Enter"], (evt) => {
  evt.preventDefault()
  document.querySelector(".btn-run").click()
})
Keyboard.on(["Alt", "Enter"], (evt) => {
  const wrapper = window.selected?.node || document
  let refs = wrapper.querySelectorAll(evt.shiftKey ? ".content-dropdown" : ".content-dropdown.below")
  if (refs.length == 0) { refs = wrapper.querySelectorAll(".reference") }
  refs[evt.shiftKey ? 0 : refs.length - 1].click()
})
Keyboard.on(["Backspace"], (evt) => {
  if (!["INPUT", "TEXTAREA"].includes(document.activeElement.tagName)) {
    if (window.selected) {
      window.selected.remove()
      record()
    }
  }
})
Keyboard.on(["Delete"], (evt) => {
  if (!["INPUT", "TEXTAREA"].includes(document.activeElement.tagName)) {
    if (window.selected) {
      window.selected.remove()
      record()
    }
  }
})
Keyboard.on(["Meta", "s"], (evt) => {
  evt.preventDefault()
  document.querySelector(".btn-save").click()
})
Keyboard.on(["Meta", "Shift", "z"], (evt) => {
  if (!["INPUT", "TEXTAREA"].includes(document.activeElement.tagName)) {
    console.log("Redo")
    const code = History.redo()
    if (code === undefined || code === null) { return }
    Statement.reloadFromText(code)
  }
})
Keyboard.on(["Meta", "z"], (evt) => {
  if (!["INPUT", "TEXTAREA"].includes(document.activeElement.tagName)) {
    console.log("Undo")
    const code = History.undo()
    if (code === undefined || code === null) { return }
    Statement.reloadFromText(code)
  }
})
Keyboard.on(["Escape"], (evt) => {
  if (!["INPUT", "TEXTAREA"].includes(document.activeElement.tagName)) {
    if (window.selected) { window.selected.selected = false }
  }
})
Keyboard.on(["/"], (evt) => {
  if (!["INPUT", "TEXTAREA"].includes(document.activeElement.tagName)) {
    if (window.selected) {
      window.selected.commented = !window.selected.commented
      record()
    }
  }
})
Keyboard.on(["Tab"], (evt) => {
  if (!["INPUT", "TEXTAREA"].includes(document.activeElement.tagName)) {
    const list = Array.from(document.querySelectorAll(".statement-wrapper"))
    evt.preventDefault()
    if (!evt.shiftKey) {
      if (!window.selected) {
        Statement.from(list[0]).selected = true
      } else {
        let idx = list.indexOf(window.selected.node) + 1
        if (idx < 0) { idx = list.length - 1 }
        if (idx > list.length - 1) { idx = 0 }
        Statement.from(list[idx]).selected = true
      }
    } else {
      if (!window.selected) {
        Statement.from(list[list.length - 1]).selected = true
      } else {
        let idx = list.indexOf(window.selected.node) - 1
        if (idx < 0) { idx = list.length - 1 }
        if (idx > list.length - 1) { idx = 0 }
        Statement.from(list[idx]).selected = true
      }
    }
  }
})

document.addEventListener("mousedown", function(event) {
  if (event.target.matches("a, .btn, input, .statement")) { return }
  if (event.button === 1) { // middle click
    Statement.reloadFromText("")
    record()
  }
});

document.addEventListener("click", function(evt) {
  if (evt.target.matches(".reference") || evt.target.matches(".content-dropdown")) {
    let target = evt.target.closest(".content-dropdown") || evt.target
    let statement = Statement.from(evt.target)
    if (!evt.target.closest(".content-dropdown") && statement) {
      statement.showDropdown()
    } else { // Top-level reference, show global dropdown opts
      const reference = target
      const referenceRect = reference.getBoundingClientRect()
      const leftPosition = (referenceRect.left + referenceRect.width / 2)
      const topPosition = referenceRect.bottom
      const top = !target.closest(".below")
      const context = target.closest(".content, .wrapper")
      const content = target.closest(".content")

      let addBlock = function(str) {
        let statement = Statement.fromText(str)
        if (top) { statement[0].moveTo(0) }
      }

      let passedOptions = function() {
        let opts = target.getAttribute("options")
        if (!opts) { return [] }

        return JSON.parse(opts).map(opt => {
          let method = Schema.methodFromStr(opt)
          if (method) {
            return {
              text: opt,
              upcoming: method.upcoming,
              callback: () => {
                let statement = new Statement({
                  type: method.type,
                  returntype: method.returntype,
                  method: method.name,
                })
                statement.moveInside(context, top)
                record()
              }
            }
          } else {
            console.error("No method found for ", opt)
          }
        })
      }

      let globalOptions = function() {
        return Schema.globalMethods(!!content).map(method => {
          let allowed = content?.getAttribute("allowed")?.split("|")
          if (allowed && allowed.indexOf("Any") < 0) {
            if (allowed.indexOf(method.returntype) < 0) {
              return // The option is not allowed
            }
          }
          return {
            text: `${method.text}`,
            upcoming: method.upcoming,
            callback: () => {
              let statement = new Statement({
                type: method.type,
                returntype: method.returntype,
                method: method.name,
              })
              if (content) {
                statement.moveInside(content, top)
              } else {
                if (top) { statement.moveTo(0) }
              }
              record()
            }
          }
        }).filter(Boolean)
      }

      let paste = {
        icon: fa("paste regular"), title: "Paste",
        callback: () => addBlock(navigator.clipboard.readText()) && record()
      }

      Dropdown.showAt(leftPosition, topPosition, [
        [paste],
        ...passedOptions().concat(globalOptions()),
        // ...(content ? passedOptions().concat(globalOptions()) : (passedOptions() || globalOptions()))
      ])
    }
  } else if (!evt.target.closest("#reference-dropdown")) {
    const dropdown = document.querySelector("#reference-dropdown")
    Dropdown.hide()
  }
})

document.addEventListener("click", function(evt) {
  if (evt.target.closest(".obj-dup")) {
    console.log("dup")
    let statement = Statement.from(evt.target)
    statement?.duplicate()
    statement && record()
    return
  }
  if (evt.target.closest(".obj-inspect")) {
    let statement = Statement.from(evt.target)
    statement?.toggleInspect()
    statement && record()
    return
  }
  if (evt.target.closest(".obj-delete")) {
    let statement = Statement.from(evt.target)
    statement?.remove()
    statement && record()
    return
  }

  if (evt.target.closest(".statement-wrapper")) {
    if (!["INPUT", "SELECT", "TEXTAREA"].includes(evt.target.tagName)) {
      let statement = Statement.from(evt.target)
      if (statement) { statement.selected = !statement.selected }
    }
  } else {
    Statement.clearSelected()
  }
})

document.addEventListener("click", function(evt) {
  if (evt.target.closest(".obj-varname")) {
    let statement = Statement.from(evt.target)
    let newname = window.prompt("Enter new name", statement._name)?.trim()
    if (newname === undefined) { return }

    try {
      statement.name = newname
      record()
    } catch (e) {
      return alert(e)
    }
  }
})

document.addEventListener("click", function(evt) {
  if (evt.target.closest(".obj-refname")) {
    let statement = Statement.from(evt.target)
    let new_ref = window.prompt("Enter new ref", statement.refname)?.trim()
    if (new_ref === undefined) { return }

    let other_ref = Statement.find(new_ref)
    if (!other_ref) {
      return window.alert("Reference not found - please enter an existing variable name")
    }
    if (!Schema.method(other_ref, statement.method)) {
      return window.alert(`New reference type "${other_ref.returntype}" cannot call "${statement.method}".`)
    }

    try {
      statement.reference = new_ref
      record()
    } catch (e) {
      return alert(e)
    }
  }
})

document.addEventListener("click", function(evt) {
  if (evt.target.closest(".obj-returntype")) {
    let statement = Statement.from(evt.target)
    Dropdown.show([
      ...Schema.all.map(type => {
        return {
          text: type.show,
          callback: () => {
            statement.returntype = type.show
            record()
          }
        }
      })
    ])
  }
})

document.addEventListener("click", function(evt) {
  let btn = evt.target.closest("btn")
  if (btn) {
    let statement = Statement.from(evt.target)
    let tokens = Statement.available(btn).reverse()
    let selectedTag = btn.parentElement.querySelector(".selected-tag")
    let defaultOpts = []
    if (btn.getAttribute("allowInput") != "false") {
      defaultOpts.push({ text: "<input>", callback: () => {
        selectedTag.innerText = ""
        record()
      } })
    }

    Dropdown.show([
      ...defaultOpts,
      ...tokens.map(token => {
        return {
          text: `${token.name}:${token.returntype}`,
          callback: () => {
            selectedTag.innerText = token.name
            record()
          }
        }
      })
    ])
  }
})

document.addEventListener("input", (event) => {
  const target = event.target;

  if (target.tagName === "INPUT" && target.type !== "checkbox" && target.type !== "radio") {
    target.addEventListener("blur", handleInputBlur, { once: true });
  } else {
    record()
  }
});
// Separate function so that `once` works
function handleInputBlur(event) {
  record()
}

document.addEventListener("mousedown", function(event) {
  if (event.button === 1 ) { // middle click
    // if statement
      // if Keyboard.isPressed("CMD")
        // Open dropdown to add new function BEFORE statement
      // else
        // Open dropdown to add new function AFTER statement
  }
});

window.oncontextmenu = function(evt) {
  evt.preventDefault()
  if (evt.target.closest(".statement-wrapper")) {
    let statement = Statement.from(evt.target)
    statement?.showDropdown()
  } else {
    Statement.save()
  }
}

sortable(document.querySelector(".statements"))
