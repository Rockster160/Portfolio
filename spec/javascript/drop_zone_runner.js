// Drives drop_zone.js and prints what happened, as JSON for drop_zone_spec.rb.
//
// There is no DOM library in this project, so this builds the smallest one the
// module actually asks for: a class list, `closest` up the parents, the three
// selectors it queries with, and listeners that can be fired by hand. Same
// approach as the other runners here.
//
// The shape under test is the real one from `_transcripts.html.erb`: the drop
// zone lives inside a <details> that is CLOSED on an application with no
// recordings yet, which is the case the page used to make impossible.

// ---- the smallest DOM the module asks for --------------------------------
function node(tag, attrs) {
  const classes = new Set();
  const el = {
    tag,
    attrs: attrs || {},
    children: [],
    parent: null,
    listeners: {},
    files: { length: 0 },
    open: false,
    textContent: "",
    classList: {
      add: (name) => classes.add(name),
      remove: (...names) => names.forEach((name) => classes.delete(name)),
      contains: (name) => classes.has(name),
      toggle: (name, on) => (on ? classes.add(name) : classes.delete(name)),
    },
    get className() { return Array.from(classes).join(" "); },
    addEventListener(name, fn) {
      (this.listeners[name] = this.listeners[name] || []).push(fn);
    },
    fire(name, event) {
      (this.listeners[name] || []).forEach((fn) => fn(event));
      return event;
    },
    append(child) {
      child.parent = this;
      this.children.push(child);
      return child;
    },
    closest(selector) {
      let here = this;
      while (here) {
        if (here.tag === selector) { return here; }
        here = here.parent;
      }
      return null;
    },
    matches(selector) {
      if (selector === "[data-drop]") { return this.attrs["data-drop"] !== undefined; }
      if (selector === "[data-drop-got]") { return this.attrs["data-drop-got"] !== undefined; }
      if (selector === "input[type=file]") { return this.tag === "input" && this.attrs.type === "file"; }
      return false;
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

function dragEvent(withFiles) {
  const event = {
    dataTransfer: withFiles
      ? { types: ["Files"], files: Object.assign([{ name: "call.txt" }], { length: 1 }) }
      : { types: ["text/plain"], files: { length: 0 } },
    prevented: false,
    preventDefault() { this.prevented = true; },
    stopPropagation() {},
  };
  return event;
}

// ---- the page -------------------------------------------------------------
const page = node("div");
const details = node("details");          // closed, as it is with no recordings
const zone = node("div", { "data-drop": "" });
const inner = node("p");                  // something to drag ACROSS inside it
const input = node("input", { type: "file" });
const got = node("p", { "data-drop-got": "" });

page.append(details);
details.append(zone);
zone.append(inner);
zone.append(input);
zone.append(got);

const doc = node("#document");

const { bindDropZones } = await import("../../app/javascript/src/drop_zone.js");
const wired = bindDropZones(page, doc);

const out = { wired, detailsOpenBefore: details.open };

// A file dragged anywhere over the window: the zone lights up and the section
// holding it opens, so there is somewhere visible to aim at.
doc.fire("dragenter", dragEvent(true));
out.afterDragEnter = { zone: zone.className, detailsOpen: details.open };

// Crossing a child fires dragleave on the parent. Counted, not toggled - a
// plain on/off would flicker the whole time the file is moving.
doc.fire("dragenter", dragEvent(true));
doc.fire("dragleave", dragEvent(true));
out.stillLitWhileMoving = zone.className;

// A drop that MISSES the zone must do nothing rather than navigate the browser
// to the file.
const missed = doc.fire("drop", dragEvent(true));
out.missedDropPrevented = missed.prevented;
out.afterMiss = zone.className;

// And the drop itself puts the file on the real input.
const landed = zone.fire("drop", dragEvent(true));
out.dropped = {
  prevented: landed.prevented,
  files: input.files.length,
  name: input.files[0] && input.files[0].name,
  zone: zone.className,
  got: got.textContent,
};

// Something dragged over the page that is NOT a file - selected text, a link -
// leaves the page alone.
const text = dragEvent(false);
doc.fire("dragover", text);
out.textDragPrevented = text.prevented;

console.log(JSON.stringify(out));
