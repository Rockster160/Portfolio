import { fa, faStack } from "./icon.js"
import { element, unwrap, field } from "./form_helpers.js"
import Statement from "./statement.js"
import Arg from "./arg.js"
import Dropdown from "./dropdown.js"
import sortable from "./sortable.js"
import Schema from "./schema.js"
import Mouse from "./mouse.js"
import Keyboard from "./keyboard.js"
import Tokenizer from "./tokenizer.js"

// import Task from "tasks/resync_garage.jil"

window.Schema = Schema
window.Statement = Statement
window.selected = undefined

// TODO: This should be specific to the current file, so that you can work on multiple at once
console.log("Load", localStorage.getItem("jilcode"));
Statement.reloadFromText(localStorage.getItem("jilcode"))

Keyboard.on(["Alt", "Enter"], (evt) => {
  const wrapper = window.selected?.node || document
  let refs = wrapper.querySelectorAll(evt.shiftKey ? ".content-dropdown" : ".content-dropdown.below")
  if (refs.length == 0) { refs = wrapper.querySelectorAll(".reference") }
  refs[evt.shiftKey ? 0 : refs.length - 1].click()
})
Keyboard.on(["Escape"], (evt) => {
  if (!["INPUT", "TEXTAREA"].includes(document.activeElement.tagName)) {
    if (window.selected) { window.selected.selected = false }
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

// const resyncGarage = Statement.reloadFromText(`
//   k495f = Hash.new({
//     e1abf = Keyval.new("request", "get")::Keyval
//   })::Hash
//   xa681 = Global.broadcast_websocket("garage", k495f)::Numeric
//   ud2b3 = Global.print("#{xa681}")::String
// `)

// const monitorGarageCell = Statement.reloadFromText(`
  // garage = Global.get_cache("garage")::Hash
  // state = garage.get("state")::String
  // timestamp = garage.get("timestamp")::Numeric
  // was = garage.get("was")::String
  // color = String.new("grey")::String
  // icon = String.new("mdi-garage_open")::String
  // direction = String.new("")::String
  // now = Date.now()::Date
  // timeDiff = now.adjust("-", timestamp)::Numeric
  // hour = Duration.new(1, "hours")::Duration
  // j4d00 = Global.if({
  //   p9635 = Boolean.compare(timeDiff, "<", hour)::Boolean
  // }, {
  //   i9c02 = Global.if({
  //     b0aab = Boolean.eq(state, "open")::Boolean
  //   }, {
  //     x5eab = Global.set(color, "orange")::Any
  //   }, {})::Any
  //   t34bb = Global.if({
  //     hf2c3 = Boolean.eq(state, "closed")::Boolean
  //   }, {
  //     wa029 = Global.set(color, "green")::Any
  //     p45a4 = Global.set(icon, "mdi-garage")::Any
  //   }, {})::Any
  //   p3d1c = Global.if({
  //     ub4b4 = Boolean.eq(state, "between")::Boolean
  //   }, {
  //     y35d8 = Global.set(color, "yellow; animation: 1s infinite blink")::Any
  //     p13e9 = Global.if({
  //       i6e2a = Boolean.eq(was, "open")::Boolean
  //     }, {
  //       x9d1f = Global.set(direction, "↓")::Any
  //     }, {
  //       b6841 = Global.set(direction, "↑")::Any
  //     })::Any
  //   }, {
  //     of2b4 = Global.comment("Been > 1 hour since last received")::None
  //   })::Any
  // }, {})::Any
  // j9d84 = Global.if({
  //   sc979 = Global.input_data()::Hash
  //   e589c = sc979.get("pressed")::Boolean
  // }, {
  //   # u7c8b = Global.if({
  // #     m49e9 = state.match("closed")::String
  // #   }, {
  // #     ic6de = Global.comment("Toggle Garage (open)")::None
  // #   }, {
  // #     p2838 = Global.comment("Toggle Garage (close)")::None
  // #   })::Any
  // }, {})::Any
  // rc012 = Global.if({
  //   w11df = Boolean.eq(color, "grey")::Boolean
  // }, {
  //   v2237 = Global.comment("Resync Garage (Trigger \`request\` through WS)")::None
  //   d379b = Task.find("70da51c2-83b3-4e50-abe1-4fbeda49279b")::Task
  //   idf9a = d379b.run("")::Task
  // }, {})::Any
  // cams = Global.comment("Custom: Home States")::String
  // ode01 = Global.return("#{cams}\\n\\n#{direction}[ico #{icon} font-size: 100px; color: #{color};]\\n\\n\\n")::String
// `)

// BUG:
//
// TODO:
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

// c2232 = Global.get_cache("ocs_event_id")::Numeric
// n4143 = Global.if({
//   hc4d6 = Boolean.compare(c2232, ">", "0")::Boolean
// }, {
//   yde88 = Date.now()::String
//   p4182 = ActionEvent.find(c2232)::ActionEvent
//   xf23e = p4182.update("", yde88, "", "")::Boolean
//   a5921 = Global.set_cache("ocs_event_id", "")::Any
// }, {
//   k2c0c = ActionEvent.add("OCSWork", "", "", "")::ActionEvent
//   d6e7a = k2c0c.id()::Numeric
//   ace78 = Global.set_cache("ocs_event_id", d6e7a)::Any
// })::Boolean
// q8ff7 = Task.find("2603d5d7-8d4e-4012-88c5-6fbacf0ccdcf")::Task
// x0914 = q8ff7.run("")::Task

// Statement.fromText(`i305a = Global.qloop({
//   z1ee2 = Global.switch(false)::Any
//   sea7b = Global.qloop({
//     lf5a4 = Boolean.new(false)::Boolean
//     l4240 = Global.qloop({
//       m02e8 = Global.switch(true)::Any
//       m02e8 = Global.switch(true)::Any
//       ef32a = Global.switch(false)::Any
//     })::Numeric
//     aee61 = Global.qloop({
//       l18d9 = Global.switch(false)::Any
//     })::Numeric
//   })::Numeric
//   n8941 = Global.switch(false)::Any
// })::Numeric`)
//
// Statement.fromText(`aeda9 = Global.if({
//   wee97 = Global.switch(false)::Any
//   k3c46 = Global.test("Default Value", 2)::Any
// }, {}, {
//   w01b4 = Global.test("Default Value", 2)::Any
// })::Boolean`)

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
              callback: () => {
                let statement = new Statement({
                  type: method.type,
                  returntype: method.returntype,
                  method: method.name,
                })
                statement.moveInside(context, top)
              }
            }
          } else {
            let rx = /"(?<word>.*?)"(?:\((?<args>.*)\))?(?:::(?<type>.*))?/;
            const match = opt.match(rx)
            if (match) {
              let { word, args, type } = match.groups
              word = unwrap(word)
              return {
                text: word,
                callback: () => {
                  let statement = new Statement({
                    type: "Global",
                    keyword: true,
                    returntype: type || "None",
                    method: word,
                    args: [
                      element("span", { innerText: word }),
                      // Args is a single "type" str for now... Fix this later.
                      ...(args && args.length > 0 ? [
                        field(Arg.fromType("TAB")),
                        field(Arg.fromType(args)),
                      ] : [])
                    ].filter(Boolean)
                  })
                  statement.moveInside(context, top)
                }
              }
            }
          }
        })
      }

      let globalOptions = function() {
        return Schema.globalMethods().map(method => {
          let allowed = content?.getAttribute("allowed")?.split("|")
          if (allowed && allowed.indexOf("Any") < 0) {
            if (allowed.indexOf(method.returntype) < 0) {
              return // The option is not allowed
            }
          }
          return {
            text: `${method.type == "Global" ? "" : method.type}.${method.name}`,
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
            }
          }
        }).filter(Boolean)
      }

      let paste = {
        icon: fa("paste regular"), title: "Paste",
        callback: () => addBlock(navigator.clipboard.readText())
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
  if (evt.target.closest(".statement-wrapper")) {
    if (!["INPUT", "SELECT", "TEXTAREA"].includes(evt.target.tagName)) {
      let statement = Statement.from(evt.target)
      console.log(statement.toString());
      console.log(statement);
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
          callback: () => statement.returntype = type.show
        }
      })
    ])
  }
})

document.addEventListener("click", function(evt) {
  let btn = evt.target.closest("btn")
  if (btn) {
    let statement = Statement.from(evt.target)
    let tokens = Statement.available(btn)
    let selectedTag = btn.parentElement.querySelector(".selected-tag")
    let defaultOpts = []
    if (btn.getAttribute("allowInput") != "false") {
      defaultOpts.push({ text: "<input>", callback: () => selectedTag.innerText = "" })
    }

    Dropdown.show([
      ...defaultOpts,
      ...tokens.map(token => {
        return {
          text: `${token.name}:${token.returntype}`,
          callback: () => selectedTag.innerText = token.name
        }
      })
    ])
  }
})

document.addEventListener("click", function(evt) {
  if (evt.target.closest(".obj-dup")) {
    let statement = Statement.from(evt.target)
    statement?.duplicate()
  }
  if (evt.target.closest(".obj-delete")) {
    let statement = Statement.from(evt.target)
    statement?.remove()
  }
})

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
