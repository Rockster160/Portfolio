import { field, element, select } from "./form_helpers.js"
import Tokenizer from "./tokenizer.js"
import Arg from "./arg.js"

export default class Method {
  constructor(data) {
    this.type = data.type
    this.name = data.name
    this.scope = data.scope
    this.stringArgs = data.args
    this.returntype = data.returntype
    this.upcoming = data.upcoming

    this.default = null
    this.optional = false
  }

  static splitToArgs(str) {
    if (!str) { return [] }

    return Tokenizer.split(str, { by: /[, ]+/ }).map(argStr => {
      return new Arg(this, argStr)
    })
  }

  get text() { // Used as the dropdown options-- currently only used by Global Functions
    if (this.type == "Global") { return `.${this.name}` }
    if (this.type == "Keyword") { return `${this.name}` }

    return `${this.type}.${this.name}`
  }

  args() {
    return Method.splitToArgs(this.stringArgs)
  }

  parsedArgs() {
    return this.args().map(arg => field(arg))
  }
}
