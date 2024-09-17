import { genHex } from "./form_helpers.js"

export default class Tokenizer {
  constructor() {
    this.hold = {}
  }

  static split(str) {
    let tokenizer = new Tokenizer
    return tokenizer.split(str)
  }

  genId() {
    return "||xx-xx-xx||".replaceAll(/xx/g, () => genHex())
  }

  // Escapes strings, then escapes each level of brackets/parens
  stepper(str) { // Should be able to pass in a block that every unwrapped value gets passed to
    // Escape strings/quotes
    let tokenized = this.tokenize(str, /\"([^"]*)\"/) // , (_m, g) => g[1]
    tokenized = this.tokenize(tokenized, /\'([^']*)\'/) // , (_m, g) => g[1]
    // Escape parens/brackets recursively
    do {
      tokenized = this.tokenize(tokenized, /\(([^(){}]*)\)/) // , (_m, g) => g[1]
      tokenized = this.tokenize(tokenized, /\{([^(){}]*)\}/) // , (_m, g) => g[1]
    } while (tokenized.match(/\(([^(){}]*)\)/) || tokenized.match(/\{([^(){}]*)\}/))
    return tokenized
  }

  split(str) {
    let tokenized = this.tokenize(str, /\"([^"]*)\"/) // , (_m, g) => g[1]
    tokenized = this.tokenize(tokenized, /\'([^']*)\'/) // , (_m, g) => g[1]
    return tokenized.split(/[, ]+/).map(token => this.untokenize(token))
  }

  trigger(token) {
    return this.hold[token]?.()
  }

  tokenize(str, regex, callback) {
    let gregex = new RegExp(regex, "g")
    do {
      str = str.replaceAll(gregex, m => {
        let id = this.genId()
        // TODO: Make sure id doesn't already exist in `hold` or in `str`
        this.hold[id] = (callback && typeof callback === "function") ? () => callback(m, m.match(regex)) : m
        return id
      })
    } while (str.match(gregex))

    return str
  }

  untokenize(str, count) {
    count = count || 1
    let token_regex = /\|\|[a-f0-9]{2}-[a-f0-9]{2}-[a-f0-9]{2}\|\|/g
    do {
      count = count == "all" ? count : count - 1
      str = str.replaceAll(token_regex, m => {
        let fn = this.hold[m]
        if (fn && typeof fn === "function") { return fn() }
        return (count == "all" || count > 0) ? this.untokenize(fn) : fn
      })
    } while ((count == "all" || count > 0) && str.match(token_regex))

    return str
  }
}

// str.match(/\{[^{}]*\}/gm)
// let str = `v9499 = Global.loop({
//   h40db = Boolean.new(false)::Boolean
//   p7726 = Global.loop({
//     z98ff = Boolean.new(false)::Boolean
//     i4cc5 = Global.loop({
//       vb4a5 = Boolean.new(false)::Boolean
//     })::Numeric
//     k541a = Boolean.new(false)::Boolean
//   })::Numeric
// })::Numeric`
// let t = new Tokenizer()
// let z = t.tokenize(str, /\{[^{}]*\}/m)
// debugger


// let str = `i305a = Global.qloop({
//   z1ee2 = Global.switch(false)::Any
//   sea7b = Global.qloop({
//     lf5a4 = Boolean.new(false)::Boolean
//     l4240 = Global.qloop({
//       m02e8 = Global.switch(false)::Any
//       ef32a = Global.switch(false)::Any
//     })::Numeric
//     aee61 = Global.qloop({
//       l18d9 = Global.switch(false)::Any
//     })::Numeric
//   })::Numeric
//   n8941 = Global.switch(false)::Any
// })::Numeric`
// let str = `{
//   z1ee2 = Global.switch(false)::Any
//   sea7b = Global.qloop({
//     lf5a4 = Boolean.new(false)::Boolean
//     l4240 = Global.qloop({
//       m02e8 = Global.switch(false)::Any
//       ef32a = Global.switch(false)::Any
//     })::Numeric
//     aee61 = Global.qloop({
//       l18d9 = Global.switch(false)::Any
//     })::Numeric
//   })::Numeric
//   n8941 = Global.switch(false)::Any
// }`
// let t = new Tokenizer()
// let z = t.tokenize(str, /\{[^{}]*\}/m)
// let u = t.untokenize(z)
// debugger
