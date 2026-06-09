import Statement from "./statement.js";
import { genHex, genLetter, prettify } from "./form_helpers.js";

export default class InlineComment {
  constructor(data = {}) {
    this.id = data.id || genLetter() + genHex(2);
    this.addToPage();
    this.text = data.text || "";
    Statement.all.push(this);
  }

  addToPage() {
    const template = document.getElementById("inline-comment-statement");
    const statementsContainer = document.querySelector(".statements");
    let clone = template.content.cloneNode(true);
    statementsContainer.appendChild(clone);

    this.node = document.getElementById("new-statement");
    this.node.id = this.id;

    const textEl = this.node.querySelector(".comment-text");
    textEl.addEventListener("keydown", (evt) => {
      if (evt.key === "Enter") {
        // Stop before blur(): the global Enter handler checks document.activeElement
        // via activeInput(), and blur() would leave it on <body> before that check runs.
        evt.stopPropagation();
        evt.preventDefault();
        textEl.blur();
      }
    });
    textEl.addEventListener("focus", () => {
      this.select();
    });
    this.node
      .querySelector(".obj-delete")
      .addEventListener("click", () => {
        this.remove();
        if (typeof window.History?.record === "function") {
          window.History.record();
        }
      });
  }

  _placeCaretAtEnd(el) {
    el.focus();
    const range = document.createRange();
    range.selectNodeContents(el);
    range.collapse(false);
    const sel = window.getSelection();
    sel.removeAllRanges();
    sel.addRange(range);
  }

  get text() {
    return this.node.querySelector(".comment-text").innerText;
  }
  set text(val) {
    this.node.querySelector(".comment-text").innerText = val || "";
  }

  // --- Compatibility with Statement API ---

  get wrapper() {
    return this.node.parentElement;
  }
  get idx() {
    return Array.prototype.indexOf.call(this.wrapper.children, this.node);
  }
  get selected() {
    return this.node.classList.contains("selected");
  }
  set selected(bool) {
    Statement.clearSelected();
    this.node.classList.toggle("selected", bool);
    if (bool) {
      window.selected = this;
      this.node.scrollIntoViewIfNeeded?.();
    } else {
      window.selected = null;
    }
  }
  select() {
    this.selected = true;
  }
  unselect() {
    this.selected = false;
  }
  focus() {
    const textEl = this.node.querySelector(".comment-text");
    this._placeCaretAtEnd(textEl);
  }

  // No-ops to match Statement interface
  get commented() { return false; }
  set commented(_) { /* not applicable */ }
  toggleComment() { /* not applicable */ }
  get inspect() { return false; }
  set inspect(_) { /* not applicable */ }
  get returntype() { return "None"; }
  get reference() { return null; }
  downReferences() { return []; }
  updateReferences() {}
  validate() {}
  clearError() {}
  addError() {}

  previous() {
    const list = Array.from(document.querySelectorAll(".statement-wrapper"));
    const idx = list.indexOf(this.node);
    for (let i = idx - 1; i >= 0; i--) {
      if (!this.node.contains(list[i])) {
        return Statement.from(list[i]);
      }
    }
  }
  next() {
    const list = Array.from(document.querySelectorAll(".statement-wrapper"));
    const idx = list.indexOf(this.node);
    for (let i = idx + 1; i < list.length; i++) {
      if (!this.node.contains(list[i])) {
        return Statement.from(list[i]);
      }
    }
  }

  moveTo(idx) {
    if (idx == this.idx) { return; }
    const siblings = this.wrapper.querySelectorAll(":scope > .statement-wrapper");
    const otherNode = siblings[idx];
    const other = Statement.from(otherNode);
    if (idx < this.idx) { this.moveBefore(other); } else { this.moveAfter(other); }
  }
  moveInside(context, top) {
    const inserter = context.querySelector(":scope > .content-dropdown.below");
    if (inserter) {
      context.insertBefore(this.node, inserter);
    } else {
      context.appendChild(this.node);
    }
    if (top) { this.moveTo(0); }
  }
  moveBefore(other) {
    if (!other) { return; }
    other.wrapper.insertBefore(this.node, other.node);
    this.moved();
  }
  moveAfter(other) {
    if (!other) { return; }
    other.wrapper.insertBefore(this.node, other.node);
    other.wrapper.insertBefore(other.node, this.node);
    this.moved();
  }
  moved() {}

  duplicate() {
    const dup = new InlineComment({ text: this.text });
    dup.moveAfter(this);
    return [dup];
  }

  remove() {
    if (this.selected) {
      (this.next() || this.previous() || Statement.first())?.select();
    }
    this.node.remove();
    Statement.all = Statement.all.filter((item) => item.id != this.id);
  }

  toString(_nest = 0, pretty = false, _parentDepth = 0) {
    // Caller's join (Statement.toCode for top-level, argValue for nested
    // content blocks) already prepends the right indent. Emitting our own
    // here doubles it inside `}, {` branches.
    //
    // Real newlines collapse to spaces — the parser regex is single-line
    // `[^\n]*?`, and ANY round-trip escape scheme for backticks/backslashes
    // collides with `form.html.erb:138`'s `code.gsub(/\``/, "\\\\\``")`,
    // which adds a backslash before every backtick on every load and would
    // accumulate per save cycle.
    const text = (this.text || "").replace(/\r?\n+/g, " ");
    const hash = prettify(pretty, "comment", "## ");
    const body = prettify(pretty, "comment", text);
    let str = hash + body;
    if (pretty) {
      str = `<span class="syntax--statement syntax--commented">${str}</span>`;
    }
    return str;
  }

  static decodeText(encoded) {
    // Undo `form.html.erb:138`'s `code.gsub(/\``/, "\\\\\``")` plus any
    // accumulation from older buggy saves. We strip every backslash run
    // immediately before a backtick — comments don't legitimately contain
    // `\\\`` literals, and accepting the constraint lets damaged tasks
    // self-heal on next save.
    return encoded.replace(/\\+`/g, "`");
  }
}
