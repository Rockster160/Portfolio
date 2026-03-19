import { unwrap } from "./form_helpers.js"
import Tokenizer from "./tokenizer.js"
import Schema from "./schema.js"
import Method from "./method.js"

export default class Arg {
  constructor(method, str) {
    this.method = method
    this.str = str
    this.typename = undefined
    this.preferredtype = undefined
    this.optional = undefined
    this.defaultval = undefined
    this.placeholder = undefined

    this.raw = undefined
    this.options = undefined

    this.content = undefined
    this.allowedtypes = "Any"

    this.breakdown(str)
  }

  static fromType(type) {
    return new Arg(null, type)
  }

  breakdown(str) {
    // Numeric
    // Numeric?
    // Numeric(0)
    // String(abc)
    // String("abc")
    // String:sup
    // Any::Boolean
    // String?("Default Value"):"Bigger Placeholder"
    let match = str.match(this.argRegex())
    if (match) {
      const { typename, preferredtype, optional, defaultval, placeholder } = match.groups
      this.typename = typename
      this.preferredtype = preferredtype || typename
      this.optional = !!optional
      if (typename === "Boolean") {
        this.defaultval = unwrap(defaultval) === "true"
      } else {
        this.defaultval = unwrap(defaultval)
      }
      this.placeholder = unwrap(placeholder)
    } else {
      // Strings for displaying words
      if (str.charAt(0) == "\"" || str.charAt(0) == "\'") { return this.raw = unwrap(str) }
      // content(String|Numeric)
      // content([a b c])
      // content(Keyval [a b c])
      match = str.match(/^(?<is_enum>enum_)?content(?:\((?<allowedtypes>[A-Z][_0-9A-Za-z|]*)? ?(?:\[(?<args>.*)\])?\))?/)
      if (match) {
        let { allowedtypes, args, is_enum } = match.groups
        this.content = true
        if (allowedtypes) { this.allowedtypes = allowedtypes }
        if (args) {
          this.options = Tokenizer.split(args, { by: /[, ]+/ }).map(item => {
            let namedMatch = item.match(/^([a-z_]\w*):([A-Z]\w*)(?:\((.+)\))?$/)
            if (namedMatch) {
              let opt = { name: namedMatch[1], type: namedMatch[2] }
              if (namedMatch[3]) { opt.defaultval = namedMatch[3] }
              // Register as a Keyword singleton method for rendering
              if (!Schema.types["Keyword"]?.singletons.find(s => s.name === opt.name)) {
                let argDef = opt.defaultval ? `${opt.type}(${opt.defaultval})` : opt.type
                Schema.types["Keyword"].addSingletonMethod(new Method({
                  scope: "singleton",
                  type: "Keyword",
                  name: opt.name,
                  args: argDef,
                  returntype: opt.type,
                }))
              }
              return opt
            }
            return item
          })
        }
        if (is_enum) { this.options = [...Schema.enumArgOptions, ...(this.options || [])] }
        return
      }
      // [optiona b c]
      // [optiona b c]?
      match = str.match(/\[(.*)\](\?)?/)
      if (match) {
        this.optional = match[2] == "?"
        this.options = Tokenizer.split(match[1], { by: /[, ]+/ }).map(item => unwrap(item))
      }
      return
    }
  }

  argRegex(flags) {
    return new RegExp([
      /^(?<typename>[A-Z][_0-9A-Za-z|]*)/,
      /(?:::(?<preferredtype>.*))?/,
      /(?<optional>\?)?/,
      /(?:\((?<defaultval>.*)\))?/,
      /(?::(?<placeholder>.*))?/,
    ].map(pattern => pattern.source).join(""), flags)
  }
}
