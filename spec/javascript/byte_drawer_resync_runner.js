// Opens the conversation drawer for real and prints what it asked the server,
// as JSON for byte_drawer_resync_spec.rb.
//
// ConversationManager owns its own DOM and its own fetches, so both are stubbed
// and recorded rather than performed: every element is a plain object that
// remembers what was done to it, and `fetch` answers from a list the runner
// swaps between steps so the second call can carry a different world than the
// first.

const requests = [];
let listing = { conversations: [], primary_id: null, default_id: null };

globalThis.fetch = async (url, opts = {}) => {
  requests.push(`${opts.method || "GET"} ${url}`);
  return {
    ok:     true,
    status: 200,
    json:   async () => listing,
  };
};

globalThis.localStorage = {
  store: {},
  getItem(k) { return this.store[k] ?? null; },
  setItem(k, v) { this.store[k] = String(v); },
};

function fakeElement(tag) {
  return {
    tag,
    classes:     [],
    attributes:  {},
    dataset:     {},
    children:    [],
    textContent: "",
    innerHTML:   "",
    hidden:      false,
    classList:   {
      add(name) { if (!this.owner.classes.includes(name)) this.owner.classes.push(name); },
      remove(name) { this.owner.classes = this.owner.classes.filter((c) => c !== name); },
    },
    appendChild(child) { this.children.push(child); return child; },
    addEventListener() {},
    setAttribute(name, value) { this.attributes[name] = value; },
    removeAttribute(name) { delete this.attributes[name]; },
    getAttribute(name) { return this.attributes[name] ?? null; },
    querySelector() { return null; },
  };
}

// One element per selector, kept, so the runner can read back what the module
// did to the drawer after it was opened.
const elements = {};

function elementFor(selector) {
  if (!elements[selector]) {
    const el = fakeElement(selector);
    el.classList.owner = el;
    elements[selector] = el;
  }
  return elements[selector];
}

globalThis.document = {
  querySelector: (selector) => elementFor(selector),
  createElement: (tag) => {
    const el = fakeElement(tag);
    el.classList.owner = el;
    return el;
  },
};

const { ConversationManager } = await import(
  "../../app/javascript/src/pages/byte/conversations.js"
);

const seen = [];
const out = {};

// The world at boot: the thread on screen, plus one holding a count.
listing = {
  conversations: [
    { id: 21, name: "Byte", mode: "buddy", unread_count: 0 },
    { id: 37, name: "Daily Audit", mode: "claude", unread_count: 2 },
  ],
  primary_id: 21,
  default_id: 21,
};

const manager = new ConversationManager({
  conversationsUrl:      "/byte/conversations",
  initialConversationId: 21,
  initialConversations:  listing.conversations,
  unreadFor:             () => 0,
  onConversations:       (list) => seen.push(list.map((c) => [c.id, c.unread_count])),
});

// The constructor refreshes in the background; let it land before counting.
await new Promise((resolve) => setTimeout(resolve, 0));
out.on_boot = requests.slice();

// The audit thread was read somewhere else, and 37 was archived from another
// device — so the list this open gets back is a smaller world than the one the
// page has been holding.
listing = {
  conversations: [{ id: 21, name: "Byte", mode: "buddy", unread_count: 0 }],
  primary_id:    21,
  default_id:    21,
};

requests.length = 0;
manager.openDrawer();

// The drawer is open on the cached list before anything has come back — the
// fetch must not be something the person waits behind.
out.open_before_fetch = elements["[data-byte-drawer]"].classes.includes("open");
out.requests_at_open  = requests.slice();

await new Promise((resolve) => setTimeout(resolve, 0));
out.seeded = seen;
out.still_open = elements["[data-byte-drawer]"].classes.includes("open");

process.stdout.write(JSON.stringify(out, null, 2));
