// Draws a Byte form holding a chips question through the real renderForm, picks
// a chip, presses Send, and prints what was drawn and what was posted, as JSON
// for byte_form_chips_spec.rb. The DOM is a small stand-in that does only what
// form.js asks of it.

class El {
  constructor(tag) {
    this.tagName = tag.toUpperCase();
    this.children = [];
    this.parent = null;
    this.dataset = {};
    this.attrs = {};
    this.listeners = {};
    this.styleProps = {};
    this.style = { setProperty: (k, v) => { this.styleProps[k] = v; } };
    this.className = "";
    this.textContent = "";
    this.checked = false;
    this.disabled = false;
    this.value = "";
  }
  set innerHTML(_v) { this.children = []; }
  appendChild(child) { child.parent = this; this.children.push(child); return child; }
  setAttribute(k, v) { this.attrs[k] = v; }
  addEventListener(type, fn) { (this.listeners[type] ||= []).push(fn); }
  dispatch(type) {
    for (let node = this; node; node = node.parent) (node.listeners[type] || []).forEach((fn) => fn({ target: this }));
  }
  contains(other) { return this.all().includes(other); }
  all() { return [this, ...this.children.flatMap((c) => c.all())]; }
  matches(sel) {
    if (sel.startsWith(".")) return this.className.split(" ").includes(sel.slice(1));
    const radio = sel.match(/^input\[type="(\w+)"\](:checked)?$/);
    if (radio) return this.tagName === "INPUT" && this.type === radio[1] && (!radio[2] || this.checked);
    return sel.split(",").map((s) => s.trim().toUpperCase()).includes(this.tagName);
  }
  querySelectorAll(sel) { return this.all().slice(1).filter((n) => n.matches(sel)); }
  querySelector(sel) { return this.querySelectorAll(sel)[0] || null; }
}

const posted = [];
globalThis.document = {
  activeElement: null,
  createElement: (tag) => new El(tag),
  querySelector: () => null,
};
globalThis.fetch = async (url, opts) => {
  posted.push({ url, body: JSON.parse(opts.body) });
  return { ok: true, json: async () => ({}) };
};

const { renderForm } = await import("../../app/javascript/src/pages/byte/message_actions/form.js");

const message = {
  metadata: {
    action_request_id: "req-1",
    form: {
      fields: [{
        key: "Who did it?", label: "Who did it?", type: "chips", required: true,
        choices: ["Rockster160", "Eve", "Alchemibluum"], value: "Eve",
        colors: { Rockster160: "#0160FF", Alchemibluum: "#A082D9" },
      }],
    },
  },
};

const container = new El("div");
renderForm(container, message);

const chips = container.querySelectorAll(".byte-msg-form-chip").map((chip) => {
  const radio = chip.children[0];
  return { text: chip.children[1].textContent, color: chip.styleProps["--chip-color"] || null, type: radio.type, checked: radio.checked, group: radio.name };
});

// Tap Alchemibluum: a radio group unchecks the rest itself.
const radios = container.querySelectorAll('input[type="radio"]');
radios.forEach((r) => { r.checked = r.value === "Alchemibluum"; });
radios[2].dispatch("change");

const send = container.querySelectorAll(".byte-msg-form-btn").find((b) => b.dataset.key === "submit");
send.listeners.click[0]();
await new Promise((r) => setTimeout(r, 0));

console.log(JSON.stringify({ chips, posted }));
