import { fa, faStack } from "./icon.js"
import { element, unwrap, field } from "./form_helpers.js"
import Statement from "./statement.js"
import Arg from "./arg.js"
import Dropdown from "./dropdown.js"
import sortable from "./sortable.js"
import Schema from "./schema.js"
import History from "./history.js"
import Mouse from "./mouse.js"
import Modal from "./modal.js"
import Keyboard from "./keyboard.js"
import saveUtils from "./save_utils.js"

window.Schema = Schema
window.Statement = Statement
window.History = History
window.formSubmitting = false
window.selected = null
window.moveStatement = null
Object.defineProperty(window, "formDirty", {
  get() {
    return this._formDirty;
  },
  set(value) {
    document.querySelector(".btn-save").classList.toggle("btn-dirty", value)
    this._formDirty = value;
  }
})

History.record = function() {
  if (History.add(Statement.toCode())) {
    formDirty = !History.noChange()
    console.log("Recorded: ", History.currentIdx)
    document.querySelector(".code-preview").innerHTML = Statement.toCode(true)
  }
}

const activeInput = (node) => {
  if (Dropdown.shown() || Modal.shown()) { return true }

  node = node || document.activeElement
  return ["INPUT", "TEXTAREA", "SELECT"].includes(node.tagName)
}
const laterMoveAfter = (other) => {
  window.moveStatement = (statement) => statement.moveAfter(other)
}
const laterMoveBefore = (other) => {
  window.moveStatement = (statement) => statement.moveBefore(other)
}
const placeStatement = (statement, context, top) => {
  if (window.moveStatement) {
    window.moveStatement(statement)
    window.moveStatement = null
  } else {
    if (context) {
      statement.moveInside(context, top)
    } else {
      if (top) { statement.moveTo(0) }
    }
  }
  statement.select()
  statement.focus()
  History.record()
}
const moveSelectionUp = () => {
  const list = Array.from(document.querySelectorAll(".statement-wrapper"))

  if (!window.selected) {
    Statement.from(list[list.length - 1]).select()
  } else {
    let idx = list.indexOf(window.selected.node) - 1
    if (idx < 0) { idx = list.length - 1 }
    if (idx > list.length - 1) { idx = 0 }
    Statement.from(list[idx]).select()
  }
  window.selected?.node?.scrollIntoViewIfNeeded()
}
const moveSelectionDown = () => {
  const list = Array.from(document.querySelectorAll(".statement-wrapper"))

  if (!window.selected) {
    Statement.from(list[0]).select()
  } else {
    let idx = list.indexOf(window.selected.node) + 1
    if (idx < 0) { idx = list.length - 1 }
    if (idx > list.length - 1) { idx = 0 }
    Statement.from(list[idx]).select()
  }
  window.selected?.node?.scrollIntoViewIfNeeded()
}

saveUtils()
// const shx = new SyntaxHighlighter(document.querySelector("code.code-preview"))
History.record() // Store initial state in history
formDirty = false // Initial load should not dirty the state

// Add a new function below/above the current selected or hovered one
Keyboard.on(["Enter", "Shift+Enter"], (evt) => {
  if (activeInput() || Dropdown.shown()) { return }
  evt.preventDefault()

  let statement = window.selected
  if (!statement) {
    statement = Statement.from(document.elementFromPoint(Mouse.x, Mouse.y))
  }

  let wrapper = null
  if (statement) {
    const node = statement.node
    wrapper = node.closest(".statement") || node.closest(".wrapper")
  }
  wrapper = wrapper || document.querySelector(".wrapper")
  let refs = wrapper.querySelectorAll(evt.shiftKey ? ".content-dropdown" : ".content-dropdown.below")
  if (refs.length == 0) { refs = wrapper.querySelectorAll(".reference") }
  if (statement) {
    const other = statement
    evt.shiftKey ? laterMoveBefore(other) : laterMoveAfter(other)
  }
  refs[evt.shiftKey ? 0 : refs.length - 1].click()
  Dropdown.moveToMouse()
})
// Quick-Run
Keyboard.on("Meta+Enter", (evt) => {
  evt.preventDefault()
  document.querySelector(".btn-run").click()
})
// Add a chain function
Keyboard.on("Control+Enter", (evt) => {
  if (!window.selected) { return }
  const wrapper = window.selected.node
  let ref = wrapper.querySelector(".reference")
  ref.click()
  Dropdown.moveToMouse()
})
// Delete selected statement
Keyboard.on(["Backspace", "Delete"], (evt) => {
  if (!activeInput() && window.selected) {
    window.selected.remove()
    History.record()
  }
})
// Remove focus and close dropdowns
Keyboard.on("Escape", (evt) => {
  if (activeInput()) {
    document.activeElement.blur()
  }
})
// Mark selected statement as commented
Keyboard.on("/", (evt) => {
  if (!activeInput() && window.selected) {
    window.selected.commented = !window.selected.commented
    History.record()
  }
})
// Focus selected statement fields
Keyboard.on(["→", "Meta+e"], (evt) => {
  if (!activeInput() && window.selected) {
    window.selected.focus()
  }
})
// Duplicate statement
Keyboard.on(["Meta+Shift+d", "Meta+d"], (evt) => {
  if (!activeInput() && window.selected) {
    evt.preventDefault()
    const dups = window.selected.duplicate()
    dups[dups.length-1]?.select()
    if (evt.shiftKey) {
      dups.reverse().forEach(item => item.moveBefore(window.selected))
    }
    History.record()
  }
})
// Tab between "selected" statements
Keyboard.on(["Tab", "Shift+Tab"], (evt) => {
  if (!activeInput()) {
    evt.preventDefault()
    if (!evt.shiftKey) {
      moveSelectionDown()
    } else {
      moveSelectionUp()
    }
  }
})
// Open config
Keyboard.on("Meta+k", (evt) => {
  if (activeInput() || Dropdown.shown()) { return }
  evt.preventDefault()

  Modal.toggle("#config-modal") // Toggle off doesn't work because modal open is activeInput
})
// Save
Keyboard.on("Meta+s", (evt) => {
  evt.preventDefault()
  document.querySelector(".btn-save").click()
})
// Copy
Keyboard.on("Meta+c", (evt) => {
  if (activeInput()) { return }
  if (!window.selected) { return }
  if (window.getSelection().toString().length > 0) { return }

  evt.preventDefault()
  navigator.clipboard.writeText(window.selected.toString())
})
// Cut
Keyboard.on("Meta+x", (evt) => {
  if (activeInput()) { return }
  if (!window.selected) { return }

  evt.preventDefault()
  navigator.clipboard.writeText(window.selected.toString())
  window.selected.remove()
  History.record()
})
// Paste
Keyboard.on(["Meta+v", "Meta+Shift+v"], async (evt) => {
  if (activeInput()) { return }
  if (!window.selected) { return }

  const statements = Statement.fromText(await navigator.clipboard.readText())
  if (evt.shiftKey) {
    await window.selected.pasteAbove()
  } else {
    await window.selected.pasteBelow()
  }
  History.record()
})
// Redo
Keyboard.on("Meta+Shift+z", (evt) => {
  if (!activeInput()) {
    const code = History.redo()
    console.log("Redo", History.savedIdx, History.currentIdx)
    if (code === undefined || code === null) { return }
    Statement.reloadFromText(code)
    formDirty = !History.noChange()
  }
})
// Undo
Keyboard.on("Meta+z", (evt) => {
  if (!activeInput()) {
    const code = History.undo()
    console.log("Undo", History.savedIdx, History.currentIdx)
    if (code === undefined || code === null) { return }
    Statement.reloadFromText(code)
    formDirty = !History.noChange()
  }
})
// ↓ opens the input dropdown menu to select different vars
Keyboard.on("↓", (evt) => {
  if (activeInput() && !Dropdown.shown()) {
    const btn = evt.target.closest(".input-wrapper")?.querySelector(":scope > btn")
    if (btn) {
      evt.preventDefault()
      btn.click()
    }
  }
})
// Move statement selection to top/bottom
Keyboard.on("Home", (evt) => {
  if (activeInput() || Dropdown.shown()) { return }
  evt.preventDefault()
  Statement.first()?.select()
})
Keyboard.on("End", (evt) => {
  if (activeInput() || Dropdown.shown()) { return }
  evt.preventDefault()
  Statement.last()?.select()
})
// Move statement selection up/down
Keyboard.on("↑", (evt) => {
  if (activeInput() || Dropdown.shown()) { return }
  evt.preventDefault()
  moveSelectionUp()
})
Keyboard.on("↓", (evt) => {
  if (activeInput() || Dropdown.shown()) { return }
  evt.preventDefault()
  moveSelectionDown()
})
// Increase statement selection up/down
Keyboard.on("Shift+↑", (evt) => {
  // increase selection up
})
Keyboard.on("Shift+↓", (evt) => {
  // increase selection down
})
// Move Statement to top/bottom
Keyboard.on("Meta+Home", (evt) => {
  if (activeInput() || Dropdown.shown()) { return }
  if (!window.selected) { return }
  evt.preventDefault()

  window.selected.moveBefore(Statement.first())
  window.selected.node.scrollIntoViewIfNeeded()
  History.record()
})
Keyboard.on("Meta+End", (evt) => {
  if (activeInput() || Dropdown.shown()) { return }
  if (!window.selected) { return }
  evt.preventDefault()

  window.selected.moveAfter(Statement.last())
  window.selected.node.scrollIntoViewIfNeeded()
  History.record()
})
// Move Statement up/down
Keyboard.on("Meta+↑", (evt) => {
  if (activeInput() || Dropdown.shown()) { return }
  if (!window.selected) { return }
  evt.preventDefault()

  window.selected.moveBefore(window.selected.previous())
  window.selected.node.scrollIntoViewIfNeeded()
  History.record()
})
Keyboard.on("Meta+↓", (evt) => {
  if (activeInput() || Dropdown.shown()) { return }
  if (!window.selected) { return }
  evt.preventDefault()

  window.selected.moveAfter(window.selected.next())
  window.selected.node.scrollIntoViewIfNeeded()
  History.record()
})
// Hot keys for toggling options or changing statement attributes
Keyboard.on("Meta+1", (evt) => {
  if (!window.selected) { return }
  evt.preventDefault()

  window.selected.inspect = !window.selected.inspect
  History.record()
})
Keyboard.on("Meta+2", (evt) => {
  if (!window.selected) { return }
  evt.preventDefault()

  window.selected.node.querySelector(".obj-varname")?.click()
})
Keyboard.on("Meta+3", (evt) => {
  if (!window.selected) { return }
  evt.preventDefault()

  window.selected.node.querySelector(".obj-refname")?.click()
})
Keyboard.on("Meta+4", (evt) => {
  if (!window.selected) { return }
  evt.preventDefault()

  window.selected.node.querySelector(".obj-returntype")?.click()
})


// Select the Statement that is focused
document.addEventListener("focusin", function(evt) {
  Statement.from(evt.target)?.select()
});

// Delete everything on middle click outside of the code
document.addEventListener("mousedown", function(event) {
  if (event.target.matches("a, .btn, input, .statement")) { return }
  if (event.button === 1) { // middle click
    Statement.reloadFromText("")
    History.record()
  }
});

// Open the dropdown to select a statement to add to the code
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
        let statement = Statement.fromText(str)[0] // FIXME: Should be all added statements, not first
        placeStatement(statement, context || content, top)
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
                placeStatement(statement, context, top)
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
              placeStatement(statement, content, top)
            }
          }
        }).filter(Boolean)
      }

      let paste = {
        icon: fa("paste regular"), title: "Paste",
        callback: () => addBlock(navigator.clipboard.readText())
      }

      Dropdown.showAt(leftPosition, topPosition, [
        // [paste],
        ...passedOptions().concat(globalOptions()),
        // ...(content ? passedOptions().concat(globalOptions()) : (passedOptions() || globalOptions()))
      ])
    }
  } else if (!evt.target.closest("#reference-dropdown")) {
    const dropdown = document.querySelector("#reference-dropdown")
    Dropdown.hide()
  }
})

// Handle dup, inspect, delete, and selected states
document.addEventListener("click", function(evt) {
  let statement = Statement.from(evt.target)
  if (!statement) { return }

  statement.select()

  if (evt.target.closest(".obj-dup")) {
    const dups = statement.duplicate()
    dups[dups.length-1]?.select()
    History.record()
  }
  if (evt.target.closest(".obj-inspect")) {
    statement.toggleInspect()
    History.record()
  }
  if (evt.target.closest(".obj-delete")) {
    const next = statement.next()
    statement.remove()
    if (next) { next.select() }
    History.record()
  }
})

// Change varname
document.addEventListener("click", function(evt) {
  if (evt.target.closest(".obj-varname")) {
    let statement = Statement.from(evt.target)
    statement.select()
    let newname = window.prompt("Enter new name", statement._name)?.trim()
    if (newname === undefined) { return }

    try {
      statement.name = newname
      History.record()
    } catch (e) {
      return alert(e)
    }
  }
})

// Change refname (object the function is being called on)
document.addEventListener("click", function(evt) {
  if (evt.target.closest(".obj-refname")) {
    let statement = Statement.from(evt.target)
    if (statement.reference === undefined) { return }
    statement.select()
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
      History.record()
    } catch (e) {
      return alert(e)
    }
  }
})

// Change returntype of statement
document.addEventListener("click", function(evt) {
  if (evt.target.closest(".obj-returntype")) {
    let statement = Statement.from(evt.target)
    statement.select()
    Dropdown.show([
      ...Schema.all.map(type => {
        return {
          text: type.show,
          callback: () => {
            statement.returntype = type.show
            History.record()
          }
        }
      })
    ])
  }
})

// Controls the pop up after clicking the left dropdown arrow on inputs
// Sets whether <input> or ref
document.addEventListener("click", function(evt) {
  let btn = evt.target.closest("btn")
  if (btn) {
    let statement = Statement.from(evt.target)
    statement.select()
    let tokens = Statement.available(btn).reverse()
    let selectedTag = btn.parentElement.querySelector(".selected-tag")
    let defaultOpts = []
    if (btn.getAttribute("allowInput") != "false") {
      defaultOpts.push({ text: "<input>", callback: () => {
        selectedTag.innerText = ""
        History.record()
      } })
    }

    Dropdown.show([
      ...defaultOpts,
      ...tokens.map(token => {
        return {
          text: `${token.name}:${token.returntype}`,
          callback: () => {
            selectedTag.innerText = token.name
            History.record()
          }
        }
      })
    ])
  }
})

document.addEventListener("click", function(evt) {
  if (activeInput()) { return }
  if (!evt.target.closest(".statements")) {
    window.selected?.unselect()
  }
})

// Record history events of inputs being edited
document.addEventListener("input", (evt) => {
  const target = evt.target;

  if (target.classList.contains("code-preview")) {
    return
  }
  if (target.tagName === "TEXTAREA" || (target.tagName === "INPUT" && target.type !== "checkbox" && target.type !== "radio")) {
    target.addEventListener("blur", handleInputBlur, { once: true });
  } else {
    History.record()
  }
});
// Separate function so that `once` works
function handleInputBlur(evt) {
  History.record()
}

// After editing the code container, update the page code
document.addEventListener("focusout", (evt) => {
  if (evt.target.classList.contains("code-preview")) {
    const code = evt.target.innerText
    if (History.add(code)) {
      formDirty = !History.noChange()
      Statement.reloadFromText(code)
    }
  }
})

// Right click a statement
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
