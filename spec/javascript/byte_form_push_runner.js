// Paints Byte forms through the real renderForm and then repaints them the way
// the server pushes - new values, a new shape, a refresh press - after the
// person has typed, ticked, focused or put things back. Prints what each step
// left on screen, as JSON for byte_form_push_spec.rb. The DOM is a small
// stand-in that does only what form.js asks of it.

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
  insertBefore(child, ref) {
    child.parent = this;
    const at = this.children.indexOf(ref);
    this.children.splice(at < 0 ? this.children.length : at, 0, child);
    return child;
  }
  get firstChild() { return this.children[0] || null; }
  remove() { if (this.parent) this.parent.children = this.parent.children.filter((c) => c !== this); }
  setAttribute(k, v) { this.attrs[k] = v; }
  addEventListener(type, fn) { (this.listeners[type] ||= []).push(fn); }
  removeEventListener(type, fn) { this.listeners[type] = (this.listeners[type] || []).filter((f) => f !== fn); }
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

let served = null;
globalThis.CSS = { escape: (s) => s };
globalThis.document = {
  activeElement: null,
  createElement: (tag) => new El(tag),
  querySelector: () => null,
  querySelectorAll: () => [],
};
globalThis.fetch = async () => ({ ok: true, json: async () => ({ message: served }) });
const tick = () => new Promise((r) => setTimeout(r, 0));

const { renderForm } = await import("../../app/javascript/src/pages/byte/message_actions/form.js");

const FIELDS = {
  Calories: { key: "Calories", label: "Calories", type: "text" },
  Caffeine: { key: "Caffeine", label: "Caffeine", type: "text" },
  Notes: { key: "Notes", label: "Notes", type: "text" },
  Meal: { key: "Add to Meal Builder", label: "Add to Meal Builder", type: "checkbox" },
  Hint: { key: "Hint", label: "Hint", type: "text" },
};
const message = (id, values, keys = ["Calories", "Caffeine", "Notes", "Meal"]) => ({
  metadata: {
    action_request_id: id,
    form: { fields: keys.map((k) => ({ ...FIELDS[k], value: values[k] ?? null })) },
  },
});

const row = (c, key) => c.querySelectorAll(".byte-msg-form-row").find((r) => r.dataset.key === key);
const input = (c, key) => row(c, key)?.querySelector("input");
const type = (c, key, value) => { input(c, key).value = value; row(c, key).dispatch("input"); };
const read = (c) => Object.fromEntries(
  c.querySelectorAll(".byte-msg-form-row").map((r) => {
    const box = r.querySelector("input");
    return [r.dataset.key, box.type === "checkbox" ? box.checked : box.value];
  }),
);
const stale = (c) => !!c.querySelector(".byte-msg-form-refresh-mark");
const out = {};

// The label of a lone checkbox ticks it.
{
  const c = new El("div");
  renderForm(c, message("label", {}));
  row(c, "Add to Meal Builder").querySelector(".byte-msg-form-label").dispatch("click");
  out.labelTicks = read(c)["Add to Meal Builder"];
}

// A push fills what nobody touched, and leaves alone what they changed.
{
  const c = new El("div");
  renderForm(c, message("push", { Notes: "Sausage Roll x5" }));
  type(c, "Calories", "900");
  input(c, "Add to Meal Builder").click();
  renderForm(c, message("push", { Calories: "1200", Caffeine: "0", Notes: "Sausage Rolls" }));
  out.push = read(c);
}

// Focusing a box that came as null, or typing and putting it back, isn't a
// change - the next push still reaches it.
{
  const c = new El("div");
  renderForm(c, message("touched", { Notes: "Roll" }));
  type(c, "Caffeine", "");
  type(c, "Notes", "Rolls");
  type(c, "Notes", "Roll");
  renderForm(c, message("touched", { Caffeine: "40", Notes: "Sausage Roll" }));
  out.touched = read(c);
}

// While someone is in the form, every other box takes the push straight
// away. The one with focus takes it as focus leaves it - for the next box
// along, not only for somewhere outside the form - unless they changed it.
{
  const c = new El("div");
  renderForm(c, message("typing", {}));
  const caffeine = input(c, "Caffeine");
  document.activeElement = caffeine;
  renderForm(c, message("typing", { Calories: "1200", Caffeine: "40" }));
  out.focused = read(c);
  out.sameBoxes = input(c, "Caffeine") === caffeine;

  document.activeElement = input(c, "Notes");
  caffeine.dispatch("focusout");
  await tick();
  out.focusMoved = read(c);

  // Typed into after the push: theirs stays, on leaving and on the next push.
  const notes = input(c, "Notes");
  renderForm(c, message("typing", { Calories: "1200", Caffeine: "40", Notes: "Server" }));
  type(c, "Notes", "Ro");
  document.activeElement = null;
  notes.dispatch("focusout");
  await tick();
  renderForm(c, message("typing", { Calories: "1300", Caffeine: "40", Notes: "Server again" }));
  out.typedAfter = read(c);
}

// The refresh button keeps focus after a tap, and doesn't hold a push back.
{
  const c = new El("div");
  renderForm(c, message("button", {}));
  renderForm(c, message("button", {}, ["Calories", "Caffeine", "Notes", "Meal", "Hint"]));
  document.activeElement = c.querySelector(".byte-msg-form-refresh");
  renderForm(c, message("button", { Calories: "1200" }, ["Calories", "Caffeine", "Notes", "Meal", "Hint"]));
  document.activeElement = null;
  out.buttonFocused = read(c).Calories;
}

// A push that changes the form's shape isn't drawn: the fields on screen stay,
// still taking the new values, and the button says there's more.
{
  const c = new El("div");
  renderForm(c, message("shape", {}));
  type(c, "Calories", "900");
  renderForm(c, message("shape", { Calories: "1200", Caffeine: "0" }, ["Calories", "Caffeine", "Notes", "Meal", "Hint"]));
  out.shape = { values: read(c), stale: stale(c) };

  // Pressing it takes the server's whole form, edits and all.
  served = message("shape", { Calories: "1200", Caffeine: "0", Hint: "5 rolls" }, ["Calories", "Caffeine", "Notes", "Meal", "Hint"]);
  c.querySelector(".byte-msg-form-refresh").click();
  await tick();
  out.replaced = { values: read(c), stale: stale(c) };
}

// Fields in a different order is a different form, and waits for the button.
{
  const c = new El("div");
  renderForm(c, message("order", {}));
  renderForm(c, message("order", { Calories: "1200" }, ["Caffeine", "Calories", "Notes", "Meal"]));
  out.reordered = { keys: Object.keys(read(c)), stale: stale(c), calories: read(c).Calories };
}

// Words land straight away, focus or not, and even when the shape is waiting.
{
  const c = new El("div");
  renderForm(c, message("words", {}));
  document.activeElement = input(c, "Calories");
  const relabelled = message("words", {}, ["Calories", "Caffeine", "Notes", "Meal", "Hint"]);
  relabelled.metadata.form.fields[0] = { ...relabelled.metadata.form.fields[0], label: "Calories (kcal)", hint: "5 rolls - 1200" };
  renderForm(c, relabelled);
  document.activeElement = null;
  const calories = row(c, "Calories");
  out.words = {
    label: calories.querySelector(".byte-msg-form-label").textContent,
    hint: calories.querySelector(".byte-msg-form-hint-server")?.textContent,
    stale: stale(c),
  };
}

console.log(JSON.stringify(out));
