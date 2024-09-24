import Method from "./method.js"

export default class Schema {
  static all = [] // List of all classes
  static types = {} // Key→Val of name→class
  static enumArgOptions = "Object Key Value Index Next Break".split(" ")

  constructor(klass) {
    this.name = klass
    this.inputtype = null
    this.singletons = []
    this.instances = []

    if (!Schema.all.some(type => type.name == this.name)) {
      Schema.all.push(this)
      Schema.types[klass] = this
    }
  }

  get show() { return this.name == "Global" ? "Any" : this.name }

  static funcRegex(flags) {
    return new RegExp([
      /(?:(?<varname>[_a-z][_0-9A-Za-z]*) ?= ?)?/,
      /(?<typename>[A-Z][_0-9A-Za-z]*)/,
      /(?::(?<objname>[_a-z][_0-9A-Za-z]*))?/,
      /\.(?<methodname>[_0-9A-Za-z]+[\!\?]?)/,
      /(?:\((?<args>.*)\))?/,
      /(?:::(?<cast>[A-Z][_0-9A-Za-z|]*))?/,
    ].map(pattern => pattern.source).join(""), flags)
  }

  static load(str) {
    // TODO: Add validations for the string
    let list = str.trim().split("\n")

    new Schema("Global")
    new Schema("None")
    new Schema("Keyword")

    let current
    list.forEach(item => {
      let match
      if (match = item.match(/(\*?)\[([A-Z][_a-zA-Z0-9]*)\](?:::([\w-]+))?/)) {
        current = this.types[match[2]] || new Schema(match[2])
        if (match[1] == "*") { current.hidden = true }
        if (match[3]) { current.inputtype = match[3] }
      } else if (current?.name == "Keyword") {
        // Keyword have special definitions since they are uppercase and don't have a # or . prefix
        const line = item.replace(/[\s\*\!]*/, "")
        match = `${current.name}.${line}`.match(Schema.funcRegex())
        const { methodname, args, cast } = match.groups
        current.addSingletonMethod(new Method({
          scope: "singleton",
          type: current.name,
          name: methodname,
          args: args,
          returntype: cast || current.name,
          upcoming: !!item.match(/^\s*\!/),
        }))
      } else if (match = (item.match(/^\s*\!?\#/) && `${current.name}.${item.replace(/  \!?#/, "")}`.match(Schema.funcRegex()))) {
        const { methodname, args, cast } = match.groups
        current.addSingletonMethod(new Method({
          scope: "singleton",
          type: current.name,
          name: methodname,
          args: args,
          returntype: cast || current.name,
          upcoming: !!item.match(/^\s*\!/),
        }))
      } else if (match = (item.match(/^\s*\!?\./) && `${current.name}.${item.replace(/  \!?\./, "")}`.match(Schema.funcRegex()))) {
        const { methodname, args, cast } = match.groups
        current.addInstanceMethod(new Method({
          scope: "instance",
          type: current.name,
          name: methodname,
          args: args,
          returntype: cast || current.name,
          upcoming: !!item.match(/^\s*\!/),
        }))
      }
    })
  }

  static instancesFor(type) { return this.types[type]?.instances || [] }

  static globalMethods(include_hidden) {
    return this.all.map(type => {
      return (type.hidden && !include_hidden) ? [] : type.singletons
    }).flat()
  }

  static methodFromStr(str) {
    if (!str) { return }
    if (!str.match(/^(?:[A-Z][_a-zA-Z0-9]*)?\.?[_a-zA-Z0-9]*$/)) { return } // Validating it matches `Type.method`

    let [type, method] = str.split(".")
    if (!method && type) { method = type; type = undefined }
    type = (!type || type == "Any") ? "Global" : type
    return (
      Schema.types[type].singletons.find(singleton => singleton.name == method) ||
      Schema.types["Keyword"].singletons.find(singleton => singleton.name == method)
    )
  }

  static method(type, name) {
    if (typeof type === "string") { // Class name
      return this.types[type].singletons.find(singleton => singleton.name == name)
    } else { // Statement
      return this.types[type.returntype].instances.find(singleton => singleton.name == name)
    }
  }

  addSingletonMethod(method) {
    this.singletons.push(method)
  }
  addInstanceMethod(method) {
    this.instances.push(method)
  }
}

Schema.load(window.load_schema)
