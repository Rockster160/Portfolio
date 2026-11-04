// Draws a Byte form through the real renderForm, taps the label of its
// checkbox, then repaints it with a filled-in value twice: once with focus left
// on the refresh button, once with focus in a text box. Prints what each step
// drew, as JSON for byte_form_refresh_spec.rb. The DOM is a small stand-in that
// does only what form.js asks of it.

class El {
  constructor(tag) {
    this.tagName = tag.toUpperCase();
    this.children = [];
    this.parent = null;
    this.dataset = {};
    this.attrs = {};
    this.listeners = {};
    this.classList = {
      add: (name) => { this.className = `${this.className} ${name}`.trim(); },
      toggle: () => {},
    };
    this.style = { setProperty: () => {} };
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
  click() {
    if (this.type === "checkbox") this.checked = !this.checked;
    this.dispatch("click");
    if (this.type === "checkbox") this.dispatch("change");
  }
  contains(other) { return this.all().includes(other); }
  all() { return [this, ...this.children.flatMap((c) => c.all())]; }
  matches(sel) {
    if (sel.startsWith(".")) return this.className.split(" ").includes(sel.slice(1));
    const typed = sel.match(/^input\[type="(\w+)"\](:checked)?$/);
    if (typed) return this.tagName === "INPUT" && this.type === typed[1] && (!typed[2] || this.checked);
    return sel.split(",").map((s) => s.trim().toUpperCase()).includes(this.tagName);
  }
  querySelectorAll(sel) { return this.all().slice(1).filter((n) => n.matches(sel)); }
  querySelector(sel) { return this.querySelectorAll(sel)[0] || null; }
}

globalThis.CSS = { escape: (s) => s };
globalThis.document = {
  activeElement: null,
  createElement: (tag) => new El(tag),
  querySelector: () => null,
  querySelectorAll: () => [],
};
globalThis.fetch = async () => ({ ok: true, json: async () => ({}) });

const { renderForm } = await import("../../app/javascript/src/pages/byte/message_actions/form.js");

const message = (calories) => ({
  metadata: {
    action_request_id: "req-1",
    form: {
      refresh: true,
      fields: [
        { key: "Calories", label: "Calories", type: "text", value: calories },
        { key: "Add to Meal Builder", label: "Add to Meal Builder", type: "checkbox", value: false },
      ],
    },
  },
});

const row = (container, key) => container.querySelectorAll(".byte-msg-form-row").find((r) => r.dataset.key === key);
const calories = (container) => row(container, "Calories").querySelector("input").value;
const checked = (container) => row(container, "Add to Meal Builder").querySelector("input").checked;

const container = new El("div");
renderForm(container, message(""));

row(container, "Add to Meal Builder").querySelector(".byte-msg-form-label").dispatch("click");
const labelToggled = checked(container);

document.activeElement = container.querySelector(".byte-msg-form-refresh");
renderForm(container, message("1200"));
const afterButton = { calories: calories(container), checked: checked(container) };

document.activeElement = row(container, "Calories").querySelector("input");
renderForm(container, message("999"));
const whileTyping = calories(container);

console.log(JSON.stringify({ labelToggled, afterButton, whileTyping }));
