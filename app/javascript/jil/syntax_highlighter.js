import Keyboard from "./keyboard.js"
import Tokenizer from "./tokenizer.js"

const isBlank = (val) => {
  if (val === null || val === undefined) { return true }
  if (Array.isArray(val) && val.length == 0) { return true }
  if (typeof val === "string" && val.trim() === "") { return true }
  if (typeof val === "object" && Object.keys(val).length === 0) { return true }
  if (typeof val === "boolean") { return false } // explicitly not blank
  return false
}

export default class SyntaxHighlighter {
  constructor(input) {
    this.caretOffset = undefined
    this.caretSelection = undefined
    this.caretRange = undefined
    this.input = input
    input.addEventListener("selectionchange", () => this.storeCaretPos())
    input.addEventListener("focusin", () => this.storeCaretPos())
    input.addEventListener("keyup", () => this.storeCaretPos()) // Arrow keys
    input.addEventListener("click", () => setTimeout(() => this.storeCaretPos()), 10)
    input.addEventListener("input", () => this.parseInput())
    // input.addEventListener("blur", () => updateStatements)
    this.pretty()
    console.log("Pretty!")
  }

  pretty() {
    let text = this.input.innerText // Plain Text without formatting
    let tokenizer = new Tokenizer(text)

    // const prettify = (escaped) => {
    //   console.log(escaped)
    //   let matches = [...escaped.matchAll(Statement.regex(true))]
    //   matches.forEach(match => {
    //     const { commented, inspect, varname, objname, methodname, args, cast } = match.groups
    //     const unescaped = tokenizer.untokenize(match[0])
    //     if (commented) {
    //       return text = text.replace(unescaped, `<span class="syntax--commented">${unescaped}</span>`)
    //     }
    //     const highlighted = [
    //       !isBlank(inspect) && inspect,
    //       !isBlank(varname) && `${varname}`,
    //       " = ",
    //       !isBlank(objname) && `${objname}`,
    //       !isBlank(methodname) && `${methodname}`,
    //       !isBlank(args) && `${tokenizer.untokenize(args)}`,
    //       !isBlank(cast) && `${cast}`,
    //     ].filter(Boolean).join()
    //     text = text.replace(unescaped, highlighted)
    //     // debugger
    //     // tokenizer.untokenize(args)
    //   })
    // }

    prettify(tokenizer.tokenizedText)
    this.input.innerHTML = text
  }

  formatText(part, tz) {
    if (isBlank(part)) { return part }

    // const whitespace = /[\s,]+/g
    // const ntz = new Tokenizer()
    // const tokenized_part = ntz.manualTokenize(part, rx.header, (t) => t.replace(/\s+/g, ""))
    // return tokenized_part.split(whitespace).map((text, ridx, all) => {
    //   text = ntz.manualUntokenize(text)
    //   const formatted = (() => {
    //     // if (text.match(new RegExp(`^${rx.column.source}$`))) {
    //     //   return `<span class=fnCol>${text}</span>`
    //     // } else
    //     if (text.match(new RegExp(`^${rx.header.source}$`))) {
    //       return `<span class=fnCol>${text}</span>`
    //     }
    //
    //     return text.replaceAll(new RegExp(`(?:\\b([a-zA-Z_]+))?(${Tokenizer.tokenRegex.source})`, "g"), (m, method, token) => {
    //       const parsed = tz.untokenize(token)
    //       if (method && parsed.startsWith("(") && parsed.endsWith(")")) {
    //         const innerVal = parsed.replace(/^\(|\)$/g, "")
    //         const formattedInner = formatText(innerVal, tz)
    //
    //         return `<span class=fnMethodOpen>${method}(</span><span class=fnMethodArgs>${formattedInner}</span><span class=fnMethodClose>)</span>`
    //       } else if (parsed.startsWith("\"") && parsed.endsWith("\"")) {
    //         return `${method || ""}<span class=fnString>${parsed}</span>`
    //       } else {
    //         return `${method || ""}${formatText(parsed, tz) || ""}`
    //       }
    //     })
    //   })()
    //
    //   return ridx < all.length - 1 ? formatted + part.match(whitespace)[ridx] : formatted;
    // }).join("")
  }

  parseInput() {
    this.storeCaretPos()
    this.formatFieldText()
    this.restoreCaretPos()
  }

  storeCaretPos() {
    this.caretSelection = window.getSelection()
    if (!this.caretSelection.focusNode) { return } // Catch initial click before focus
    this.caretRange = this.caretSelection.getRangeAt(0)
    const preCaretRange = this.caretRange.cloneRange()
    preCaretRange.selectNodeContents(this.input)
    preCaretRange.setEnd(this.caretRange.endContainer, this.caretRange.endOffset)
    this.caretOffset = preCaretRange.toString().length
  }
  restoreCaretPos() {
    const walker = document.createTreeWalker(this.input, NodeFilter.SHOW_TEXT, null, false)
    let node
    let newCursorOffset = this.caretOffset
    while (node = walker.nextNode()) {
      if (newCursorOffset <= node.textContent.length) {
        this.caretRange.setStart(node, newCursorOffset)
        this.caretRange.collapse(true)
        break
      } else {
        newCursorOffset -= node.textContent.length
      }
    }

    this.caretSelection.removeAllRanges()
    this.caretSelection.addRange(this.caretRange)
  }
}

// Keyboard.on("Escape", (evt) => {
//   if (Modal.isShown()) {
//     evt.preventDefault()
//     Modal.hide()
//   }
// })
//
// document.addEventListener("click", function(evt) {
//   if (evt.cancelBubble) { return }
//
//   const opener = evt.target.closest("[data-modal]")
//   if (opener) {
//     return Modal.show(opener.getAttribute("data-modal"))
//   }
//
//   if (evt.target.classList.contains("modal-wrapper")) {
//     return Modal.hide()
//   }
// })
