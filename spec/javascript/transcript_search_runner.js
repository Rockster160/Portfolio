// Drives transcript_search.js and prints what happened, as JSON for
// transcript_search_spec.rb.
//
// There is no DOM library in this project, so this builds the smallest one the
// module asks for: a class list, attribute selectors, a settable `innerHTML`
// kept apart from `textContent`, and listeners that can be fired by hand. Same
// approach as the other runners here.
//
// The shape under test is the real one from the transcript page and from
// `_note.html.erb`: a query box, a count, and turns whose NAME and WORDS are
// both searchable - "what did the recruiter say" and "what was said about the
// salary" are the same question asked two ways.

// ---- the smallest DOM the module asks for --------------------------------
function node(tag, attrs) {
  const classes = new Set();
  const el = {
    tag,
    attrs: attrs || {},
    children: [],
    parent: null,
    listeners: {},
    value: "",
    html: null,
    words: "",
    classList: {
      add: (name) => classes.add(name),
      remove: (...names) => names.forEach((name) => classes.delete(name)),
      contains: (name) => classes.has(name),
      toggle: (name, on) => (on ? classes.add(name) : classes.delete(name)),
    },
    get className() { return Array.from(classes).join(" "); },
    // What the element says. The module reads it once per part and then writes
    // marked-up HTML over it, so the two are kept apart here the way a real
    // node keeps them.
    get textContent() { return this.words; },
    set textContent(said) { this.words = said; this.html = said; },
    get innerHTML() { return this.html; },
    set innerHTML(said) { this.html = said; },
    addEventListener(name, fn) {
      (this.listeners[name] = this.listeners[name] || []).push(fn);
    },
    fire(name, event) {
      (this.listeners[name] || []).forEach((fn) => fn(event || {}));
      return event;
    },
    append(child) {
      child.parent = this;
      this.children.push(child);
      return child;
    },
    matches(selector) {
      const named = selector.replace(/[[\]]/g, "");
      return this.attrs[named] !== undefined;
    },
    querySelectorAll(selector) {
      const found = [];
      const walk = (where) => where.children.forEach((child) => {
        if (child.matches(selector)) { found.push(child); }
        walk(child);
      });
      walk(this);
      return found;
    },
    querySelector(selector) { return this.querySelectorAll(selector)[0] || null; },
  };
  return el;
}

function turn(pane, who, said) {
  const li = node("li", { "data-turn": "" });
  const name = node("span", { "data-turn-text": "" });
  const words = node("p", { "data-turn-text": "" });
  name.textContent = who;
  words.textContent = said;
  li.append(name);
  li.append(words);
  pane.append(li);
  return li;
}

// ---- the page -------------------------------------------------------------
const page = node("div");
const pane = node("div", { "data-transcript-search": "" });
const box = node("input", { "data-transcript-query": "" });
const count = node("span", { "data-transcript-count": "" });
count.textContent = "4 turns";

page.append(pane);
pane.append(box);
pane.append(count);

const asked = turn(pane, "Casey", "How do you handle <em>disagreeing</em> with a teammate?");
const answered = turn(pane, "Rocco", "I would rather have the argument early.");
const money = turn(pane, "Casey", "The range on this one is 180 to 210.");
const closed = turn(pane, "Rocco", "That works. Early is better than late for me.");

const { bindTranscriptSearch } = await import("../../app/javascript/src/transcript_search.js");
const out = { wired: bindTranscriptSearch(page), resting: count.textContent };

const turns = () => [asked, answered, money, closed];
const showing = () => turns().filter((li) => !li.classList.contains("is-unmatched")).length;

const search = function (query) {
  box.value = query;
  box.fire("input");
  return { count: count.textContent, shown: showing(), pane: pane.className };
};

// The words, which is the common case - and the hit is lit up where it is.
out.forWords = search("early");
out.markedUp = answered.children[1].innerHTML;

// The NAME, because who said it is the same question asked the other way.
out.forName = search("casey");

// A word nobody said. The count is the only thing that can say so - an empty
// list and a transcript that never loaded look identical.
out.forNothing = search("kubernetes");

// Emptying the box puts the whole conversation back, marks and all removed.
out.cleared = search("");
out.clearedMarkup = answered.children[1].innerHTML;

// Escape empties it too, from inside the box.
box.value = "early";
box.fire("input");
box.fire("keydown", { key: "Escape" });
out.afterEscape = { value: box.value, shown: showing() };

// The turn whose words hold angle brackets - the mark goes in as HTML, so the
// words have to come back out escaped rather than as markup of their own.
out.escapesTheWords = search("disagreeing") && asked.children[1].innerHTML;

console.log(JSON.stringify(out));
