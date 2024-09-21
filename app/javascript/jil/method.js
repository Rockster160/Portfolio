import sortable from "./sortable.js"
import { field, element, select } from "./form_helpers.js"
import Tokenizer from "./tokenizer.js"
import Arg from "./arg.js"

export default class Method {
  static tokenizer = this.tokenizer = new Tokenizer

  constructor(data) {
    this.type = data.type
    this.name = data.name
    this.scope = data.scope
    this.stringArgs = data.args
    this.returntype = data.returntype
    this.upcoming = data.upcoming
    this.tokenizer = new Tokenizer

    this.default = null
    this.placeholder = null
    this.optional = false
  }

  static placeholder(name, str) {
    const { returntype } = str.match(/(?:::(?<returntype>\w+))/)?.groups || {}

    return new Method({
      scope: "singleton",
      type: "Global",
      name: name,
      args: str.match(/\(ANY\)/) ? `"${name}" TAB Any` : `"${name}"`,
      returntype: returntype || "Any",
    })
  }

  static splitToArgs(str) {
    if (!str) { return [] }

    str = this.tokenize(str, /\"(.*?)\"/)
    str = this.tokenize(str, /(?:enum_)?content\(([A-Z][_0-9A-Za-z|]*)? ?\[(.*?)\]\)/)
    str = this.tokenize(str, /\[(.*?)\]/)
    return str.split(" ").map(argStr => {
      return new Arg(this, this.untokenize(argStr, "all"))
    })
  }

  static trigger(token) { return this.tokenizer.trigger(token) }
  static tokenize(str, regex, callback) { return this.tokenizer.tokenize(str, regex, callback) }
  static untokenize(str, opt) { return this.tokenizer.untokenize(str, opt) }

  trigger(token) { return this.tokenizer.trigger(token) }
  tokenize(str, regex, callback) { return this.tokenizer.tokenize(str, regex, callback) }
  untokenize(str, opt) { return this.tokenizer.untokenize(str, opt) }

  args() {
    return Method.splitToArgs(this.stringArgs)
  }

  parsedArgs() {
    return this.args().map(arg => field(arg))
  }
}
