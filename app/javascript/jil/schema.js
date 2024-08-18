import Method from "./method.js"

export default class Schema {
  static all = [] // List of all classes
  static types = {} // Key→Val of name→class
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

    let current
    list.forEach(item => {
      let match
      if (match = item.match(/\[([A-Z][_a-zA-Z0-9]*)\](?:::([\w-]+))?/)) {
        current = this.types[match[1]] || new Schema(match[1])
        if (match[2]) { current.inputtype = match[2] }
      } else if (match = item.match(/^\s*\#/) && `${current.name}.${item.replace(/  #/, "")}`.match(Schema.funcRegex())) {
        const { methodname, args, cast } = match.groups
        current.addSingletonMethod(new Method({
          scope: "singleton",
          type: current.name,
          name: methodname,
          args: args,
          returntype: cast || current.name,
        }))
      } else if (match = item.match(/^\s*\./) && `${current.name}.${item.replace(/  \./, "")}`.match(Schema.funcRegex())) {
        const { methodname, args, cast } = match.groups
        current.addInstanceMethod(new Method({
          scope: "instance",
          type: current.name,
          name: methodname,
          args: args,
          returntype: cast || current.name,
        }))
      }
    })
  }

  static instancesFor(type) { return this.types[type]?.instances || [] }

  static globalMethods() {
    return this.all.map(type => {
      return type.singletons
    }).flat()
  }

  static methodFromStr(str) {
    if (!str) { return }
    if (!str.match(/^(?:[A-Z][_a-zA-Z0-9]*)?\.?[a-z][_a-zA-Z0-9]*$/)) { return }
    let [type, method] = str.split(".")
    if (!method && type) { method = type; type = undefined }
    type = (!type || type == "Any") ? "Global" : type
    return this.types[type].singletons.find(singleton => singleton.name == method)
  }

  static method(type, name) {
    if (typeof type === "string") { // Class name
      if (["Break", "Index", "Next"].indexOf(name) >= 0) { return Method.placeholder(name) }
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
