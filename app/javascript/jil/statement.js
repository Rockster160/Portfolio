import { fa, faStack } from "./icon.js"
import { genHex, genLetter } from "./form_helpers.js"
import Dropdown from "./dropdown.js"
import Tokenizer from "./tokenizer.js"

export default class Statement {
  static all = []
  static wrapper = document.querySelector(".statements")
  constructor(data) {
    this.id = data.id || (genLetter() + genHex(2))

    this.validateName(data?.name)
    this.addToPage()

    this.name = "" // Triggers name callback - setting "no name" class
    if (data) {
      for (const [key, value] of Object.entries(data)) { this[key] = value }
    }

    Statement.all.push(this)
  }
  static toCode() {
    let topLevel = document.querySelectorAll(".statements > .statement-wrapper")
    return Array.from(topLevel).map(statement => {
      return Statement.from(statement).toString()
    }).join("\n")
  }
  static save() {
    let code = Statement.toCode()
    console.log(code)
    localStorage.setItem("jilcode", code)
    console.log("Saved!")
  }
  static find(id) {
    return this.all.find(statement => statement.id == id || statement.name == id)
  }
  static from(element) {
    return Statement.find(element.closest(".statement-wrapper")?.id)
  }
  static nameTaken(name, ignore) {
    if (!name) { return false }

    return Statement.all.some(statement => {
      if (ignore && statement.id == ignore.id) { return false }
      return statement._name == name
    })
  }

  static regex(escaped_args) {
    // wb74e = Global.test("Default Value", 2)::Any
    // p6ec7 = p4b96.split(", ")::Array
    // e739e = Boolean.new(true)::Boolean
    // d022b = Boolean.or(e739e, e739e)::Boolean
    // uef07 = Hash.new({
    //   id7e8 = Keyval.new("asd", "a")::Keyval
    //   l6c23 = Keyval.new("dsa", "b")::Keyval
    //   y1800 = Keyval.new("foo", "c")::Keyval
    // })::Hash
    // lc174 = Array.new({
    //   ha34e = String.new("Hello, world")::String
    //   m7923 = Numeric.new("75")::Numeric
    // })::Array
    let captComment = /(?<commented>\#)? */
    let captVarName = /(?:(?<varname>[_a-z][_0-9A-Za-z]*) *= *)? */
    let captObjName = /(?<objname>[_a-zA-Z][_0-9A-Za-z]*)/
    let captMethodName = /\.(?<methodname>[_0-9A-Za-z]+[!?]?)/
    // let captArgs = /\((?<args>[^\(\)]*\(((?:(?!\()[^\(\)]*|\([^()]*\))*)\)[^\(\)]*)\)/ // Only insides
    let captArgs = escaped_args ? /(?<args>\|\|[a-f0-9]{2}-[a-f0-9]{2}-[a-f0-9]{2}\|\|)/ : /\((?<args>[\s\S]*)\)/ // First to last
    let captCast = /::(?<cast>[A-Z][_0-9A-Za-z]*)/
    let fullRegex = new RegExp([
      captComment,
      captVarName,
      captObjName,
      captMethodName,
      captArgs,
      captCast,
    ].map(pattern => pattern.source).join(""), "gm")

    return fullRegex
  }
  static reloadFromText(text) {
    Statement.all.forEach(item => item.remove())
    this.fromText(text)
  }
  static fromText(text) {
    if (!text) { return }
    [...text.matchAll(/^ *(?<varname>[_a-z][_0-9A-Za-z]*) *=/gm)].forEach(m => {
      let { varname } = m.groups
      if (Statement.find(varname)) {
        text = text.replaceAll(varname, (genLetter() + genHex(2)))
      }
    })

    let adds = []
    let tokenizer = new Tokenizer()
    let escaped = tokenizer.stepper(text)
    let matches = [...escaped.matchAll(Statement.regex(true))]
    matches.forEach(match => {
      const { commented, varname, objname, methodname, args, cast } = match.groups

      let statement = new Statement({
        id: varname,
        name: varname,
        returntype: cast,
      })
      if (commented) {
        statement.commented = true
      }
      if (/^[A-Z]/.test(objname)) {
        statement.type = objname
      } else {
        statement.reference = objname
      }
      statement.method = methodname
      let argString = tokenizer.untokenize(args, "all")
      statement.argString = argString.substr(1, argString.length-2) // Remove wrapping parens

      adds.push(statement)
    })

    return adds
  }
  static available(btn, statement) {
    statement = (statement || btn)?.closest(".statement-wrapper")
    let wrapper = statement?.closest(".content, .statements")
    if (!wrapper) { return [] }

    let types = btn.getAttribute("inputtype")?.split("|") || ["Any"]

    let found = []
    let previous = statement.previousElementSibling
    while (previous) {
      if (previous.classList.contains("statement-wrapper")) {
        let prevStatement = Statement.from(previous)
        if (prevStatement) {
          if (types.indexOf("Any") >= 0 || types.indexOf(prevStatement.returntype) >= 0) {
            found.push(prevStatement)
          }
        }
      }
      previous = previous.previousElementSibling
    }

    return [...found, ...this.available(btn, wrapper.parentElement)]
  }

  static clearSelected() {
    window.selected = undefined
    document.querySelectorAll(".statement-wrapper").forEach(item => {
      item.classList.remove("upper-selected")
      item.classList.remove("selected")
      item.classList.remove("lower-selected")
    })
  }

  get wrapper() { return this.node.parentElement }

  flash() {
    this.node.classList.remove("flash")
    this.node.classList.remove("fade-out")
    clearTimeout(this.flashTimer)

    this.node.classList.add("flash")
    setTimeout(() => this.node.classList.add("fade-out"), 50)
    this.flashTimer = setTimeout(() => {
      this.node.classList.remove("flash")
      this.node.classList.remove("fade-out")
    }, 300)
  }

  addToPage() {
    const template = document.getElementById("statement")
    const statementsContainer = document.querySelector(".statements")

    let clone = template.content.cloneNode(true)
    statementsContainer.appendChild(clone)

    this.node = document.getElementById("new-statement")
    this.node.id = this.id
  }

  duplicate() {
    let dups = Statement.fromText(this.toString())
    dups.forEach(dup => dup.moveAfter(this))
  }

  downReferences() {
    return Statement.all.map(statement => statement.refId == this.node.id ? statement : null).filter(Boolean)
  }
  updateReferences() {
    this.downReferences().forEach(statement => statement.reference = this)
  }

  get selected() { return this.node.classList.contains("selected") }
  set selected(bool) {
    Statement.clearSelected()
    if (bool) { window.selected = this }
    this.node.classList.toggle("selected", bool)
    this.reference?.node.classList.toggle("upper-selected", bool)
    this.downReferences().forEach(item => item.node.classList.toggle("lower-selected", bool))
  }

  get reference() { return this._reference }
  set reference(ref) {
    let foundRef
    if (typeof ref === "string") {
      foundRef = Statement.find(ref)
      if (foundRef) { ref = foundRef }
    } else { // Is a Statement
      foundRef = ref
    }
    if (ref && !foundRef) {
      this._reference = null
      this.refId = ref
      this.refname = "?"
      this.addError(`Reference ${ref} not found.`)
    } else if (foundRef) {
      this._reference = foundRef
      this.refId = foundRef.id
      this.type = foundRef.returntype
      this.refname = foundRef._name || "obj"
    } else {
      this._reference = null
      this.refId = null
      this.refname = this.scope == "instance" ? "?" : null
    }
    this.node.querySelector(".obj-refname").classList.toggle("hidden", this.scope == "singleton")
    this.node.querySelector(".obj-type").classList.toggle("hidden", this.scope == "instance")
    this.validate()
  }
  validate() {
    this.clearError()
    // Each arg that points to a token should verify the token exists AND returns the correct filetype
    // Make sure reference is defined in the current context
    // Make sure reference is defined before `this`
    if (this.scope == "instance" && !this.reference) {
      this.addError("Reference not found")
    }
    console.log(this.name, this.method, this.scope)
    // Make sure `type` is imported/defined
    // Make sure `method` is defined on `type` as respective class/instance level
    // Make sure each arg is valid
  }
  clearError() {
    this.error = false
    this.errors = []
    let warning = this.node.querySelector(".obj-errors")
    warning.title = ""
    warning.classList.add("hidden")
  }
  addError(msg) {
    this.error = true
    if (this.node) { this.node.classList.add("error") }
    (this.errors = this.errors || []).push(msg)
    let warning = this.node.querySelector(".obj-errors")
    warning.title = this.errors.join("\n")
    warning.classList.toggle("hidden", !this.error)
  }

  validateName(newname) {
    if (!newname) {
      // Empty name is allowed
    } else if (!newname.match(/^[_a-z0-9]+$/i)) {
      throw new Error("Name must match [_a-z0-9]")
    } else if (!newname.match(/^[_a-z]/)) {
      throw new Error("Name must begin with a lowercase letter!")
    } else if (Statement.nameTaken(newname, this)) {
      throw new Error("Name has already been taken!")
    }
  }

  get name() { return this.node.querySelector(".obj-varname").innerText  }
  set name(newname) {
    if (!newname) { newname = "" }
    this.validateName(newname)

    let oldName = this._name || this.id
    this._name = newname || this.id
    let nameNode = this.node?.querySelector(".obj-varname")
    if (nameNode) { nameNode.innerText = this._name }

    if (nameNode) {
      nameNode.classList.remove("noname")
      this.node.querySelector(".obj-eq").classList.remove("hidden")
    }

    document.querySelectorAll(".selected-tag").forEach(item => {
      if (item.innerText == oldName) { item.innerText = newname }
    })
    this.updateReferences()
  }
  get returntype() { return this.node.querySelector(".obj-returntype").innerText }
  set returntype(new_type) {
    this._returntype = new_type
    this.node.querySelector(".obj-returntype").innerText = new_type == "Global" ? "Any" : new_type

    this.updateReferences()
  }
  get refname() { return this.node.querySelector(".obj-refname").innerText }
  set refname(new_ref) {
    this.node.querySelector(".obj-refname").innerText = new_ref
  }
  get type() { return this._type || this.node.querySelector(".obj-type").innerText }
  set type(new_type) {
    this._type = new_type
    this.node.querySelector(".obj-type").innerText = new_type
    this.node.querySelector(".obj-type").classList.toggle("hidden", new_type == "Global" || this.scope == "instance")
    this.node.querySelector(".obj-dot").classList.toggle("hidden", new_type == "Global")
  }
  get scope() { return this._scope }
  set scope(new_scope) {
    this._scope = new_scope
    this.type = this.type
  }
  get method() { return this.node.querySelector(".obj-method").innerText }
  set method(new_method) {
    this.node.querySelector(".obj-method").innerText = new_method
    let argsContainer = this.node.querySelector(".obj-args")
    argsContainer.innerHTML = ""
    if (this.keyword) { return }

    let methodObj = Schema.method(this.reference || this.type, new_method)
    if (methodObj) {
      this.scope = methodObj.scope
      methodObj.parsedArgs().forEach(item => argsContainer.appendChild(item))
    } else {
      this.addError(`Unable to call ${new_method} on ${this.refname}::${this.type}`)
    }
  }

  get idx() { return Array.prototype.indexOf.call(this.wrapper.children, this.node) }
  moveTo(idx) {
    if (idx == this.idx) { return }

    let siblings = this.wrapper.querySelectorAll(":scope > .statement-wrapper")
    let otherNode = siblings[idx]
    let other = Statement.from(otherNode)
    if (idx < this.idx) {
      this.moveBefore(other)
    } else {
      this.moveAfter(other)
    }
  }
  moveInside(context, top) {
    let inserter = context.querySelector(":scope > .content-dropdown.below")
    if (inserter) {
      context.insertBefore(this.node, inserter)
    } else {
      context.appendChild(this.node)
    }
    if (top) { this.moveTo(0) }
  }
  moveBefore(other) {
    this.wrapper.insertBefore(this.node, other.node)
    this.moved()
  }
  moveAfter(other) {
    // There's no insertAfter, so insert `this` before the new one, then move the new one before it
    other.wrapper.insertBefore(this.node, other.node)
    other.wrapper.insertBefore(other.node, this.node)
    this.moved()
  }
  moved() {
    this.updateReferences()
  }

  pasteAbove() {
    // let statement = Statement.fromText(navigator.clipboard.readText())
    // statement?.moveBefore(this)
  }
  pasteBelow() {
    // let statement = Statement.fromText(navigator.clipboard.readText())
    // statement?.moveAfter(this)
  }

  remove() {
    this.downReferences().forEach(statement => {
      // statement.reference = null
      statement._reference = null
      statement.refId = null
      statement.addError("Parent statement has been removed")
    })
    this.node.remove()
    Statement.all = Statement.all.filter(item => item.id != this.id)
  }

  get commented() { return this._commented }
  set commented(bool) {
    this._commented = bool
    this.node.classList.toggle("commented", this.commented)
    this.updateReferences()
  }
  toggleComment() {
    this.commented = !this.commented
  }

  dropdownOpts() {
    let dup = { icon: fa("clone regular"), title: "Duplicate", callback: () => this.duplicate() }
    let copy = { icon: fa("regular clipboard"), title: "Copy to Clipboard", callback: () => navigator.clipboard.writeText(this.toString()) }
    let pasteup = { text: "↑", icon: fa("paste regular"), title: "Paste Above", callback: () => this.pasteAbove() }
    let pastedown = { text: "↓", icon: fa("paste regular"), title: "Paste Below", callback: () => this.pasteBelow() }
    let comment = { icon: fa("hashtag"), title: "Toggle Comment", callback: () => this.toggleComment() }

    return [
      [dup, copy, pasteup, pastedown, comment],
      ...Schema.instancesFor(this.returntype).map(method => {
        return {
          text: `#${method.name}`,
          callback: () => {
            (new Statement({
              reference: this,
              type: method.type,
              returntype: method.returntype,
              method: method.name,
            })).moveAfter(this)
          }
        }
      })
    ]
  }

  showDropdown() { Dropdown.show(this.dropdownOpts()) }

  get args() {
    return Array.from(this.node.querySelector(".obj-args").children)
  }
  set args(newArgs) {
    let argsContainer = this.node.querySelector(".obj-args")
    newArgs.forEach(item => argsContainer.appendChild(item))
  }
  set argString(str) {
    let vals = Tokenizer.split(str) // ['Default Value', '2']
    let argsContainer = this.node.querySelector(".obj-args")
    let inputs = Array.from(argsContainer.querySelectorAll(":scope > .input-wrapper, :scope > .content"))
    inputs.forEach((wrapper, idx) => {
      let val = vals[idx]
      if (wrapper.classList.contains("content")) {
        let tokenizer = new Tokenizer()
        let escaped = tokenizer.tokenize(str, /\{[^{}]*\}/m)
        let section = escaped.split(/,? /)[idx]
        let unwrap = tokenizer.untokenize(section) // Unwrap once, giving only the current level fns
        let args = unwrap.split("\n").slice(1, -1) // Remove wrapping brackets

        args.forEach(arg => {
          let statement = Statement.fromText(tokenizer.untokenize(arg, "all"))[0]
          if (statement) { statement.moveInside(wrapper) }
        })
      } else {
        if (/^[_a-z][0-9A-Za-z_]*$/.test(val) && (val != "true" && val != "false")) {
          let selectedTag = wrapper.querySelector(":scope > .selected-tag")
          if (selectedTag) {
            selectedTag.innerText = val
          } else {
            let select = wrapper.querySelector("select")
            select.value = "<dynamic>"
            let dynamicWrapper = wrapper.querySelector(".dynamic.input-wrapper")
            dynamicWrapper.classList.remove("hidden")
            dynamicWrapper.querySelector(":scope > .selected-tag").innerText = val
          }
        } else {
          let inputSelector = [
            "input",
            "textarea",
            "select",
          ].map(type => `:scope > ${type}`).join(", ")
          let input = wrapper.querySelector(inputSelector)
          input = input || wrapper.querySelector(":scope > .switch > input") // Checkbox nested under .switch
          if (!input) { return }
          if (input.type == "checkbox") {
            input.checked = val == "true"
          } else {
            input.value = val.replaceAll(/(^['"]|["']$)/g, "")
            if (input.value == "<dynamic>") {
              let dynamicWrapper = wrapper.querySelector(".dynamic.input-wrapper")
              dynamicWrapper.classList.remove("hidden")
            }
          }
        }
      }
    })
  }
  argValue(arg, nest) {
    nest = nest || 0
    let tag = arg.querySelector(":scope > .selected-tag")?.innerText
    tag = tag || arg.querySelector(":scope > .dynamic > .selected-tag")?.innerText
    if (tag) { return tag }
    let inputSelector = [
      "input",
      "textarea",
      "select",
    ].map(type => `:scope > ${type}`).join(", ")
    let input = arg.querySelector(inputSelector)
    input = input || arg.querySelector(":scope > .switch > input") // Checkbox nested under .switch

    if (arg.classList.contains("content")) {
      let statements = Array.from(arg.querySelectorAll(":scope > .statement-wrapper"))
      if (statements.length == 0) { return "{}" }
      let indent = "  ".repeat(nest)
      let str = `{\n${indent}  `
      str += statements.map(wrapper => Statement.from(wrapper).toString(nest+1)).join(`\n  ${indent}`)
      str += `\n${indent}}`
      return str
    }

    if (!input && arg.querySelector(":scope > .selected-tag")) { return JSON.stringify("") }
    if (!input) { return } // Words (And, DO, IF, etc...)
    switch (input.tagName.toLowerCase()) {
      case "textarea":
      case "select":
      case "input":
        switch (input.type) {
          case "number": return JSON.stringify(parseFloat(input.value));
          case "checkbox": return JSON.stringify(input.checked);
          default: return JSON.stringify(input.value);
        }
      default:
        console.log(`Unknown value for type:${input.tagName.toLowerCase()}`);
    }
  }

  toString(nest) {
    let str = ""
    if (this._name) { str += `${this._name} = ` }
    if (this._reference) {
      str += `${this._reference.name || this._reference.id}`
    } else {
      str += this.type
    }
    str += `.${this.method}(`
    str += this.args.map(arg => this.argValue(arg, nest)).filter(Boolean).join(", ")
    // iterate through obj-args, pull the value from inputs- when a content block, wrap inside {}
    str += `)::${this.returntype}`
    if (this.commented) {
      str = str.split("\n").map(line => `# ${line}`).join("\n")
    }
    return str
  }
}