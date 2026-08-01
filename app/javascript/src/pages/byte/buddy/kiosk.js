// The wall tablet. Half the screen is the pet, half is the routines you tap,
// and there is nothing else on it — no header, no thread, no composer.
//
// That last part is what this file is really about. Everywhere else, a tap
// lands in a conversation you can read: the receipt scrolls into the thread,
// and a step that needs an answer renders its form in the bubble that asked.
// With no thread, both of those go nowhere. So:
//
//   * whatever the pet says surfaces as a bubble over its half, for as long as
//     it takes to read and no longer;
//   * a question mid-sequence covers the buttons until it's answered, using
//     the very same renderers the thread uses, so a routine built around
//     `ask_me` behaves here exactly as it does in chat.
//
// Nothing about running a routine is kiosk-specific. The button posts to the
// same endpoint the Quick popover does, which replays the steps with no model
// turn behind them.

import { renderForm } from "../message_actions/form";
import { renderMultiSelect } from "../message_actions/multi_select";
import { quickOrder, NO_ROUTINES } from "./routine_order";

const ROUTINES_URL = "/buddy/routines";
const PIN_URL = "/byte/kiosk/conversation";

// How long a line stays up. Long enough to look away and back for a short
// receipt, and scaled by length so a briefing isn't yanked mid-sentence.
const SAY_BASE_MS = 6000;
const SAY_PER_CHAR_MS = 45;
const SAY_MAX_MS = 30000;
// Matches the opacity transition in byte.scss, so the text fades rather than
// disappearing between two frames.
const SAY_FADE_MS = 260;

// The three message shapes that are a question rather than a statement: an
// editable form, a checklist waiting on a tick, and a question relayed here
// from someone else's companion.
const ASK_TOOLS = new Set([
  "buddy_form",
  "buddy_proposals",
  "buddy_relay_answer",
]);

function csrfToken() {
  const meta = document.querySelector('meta[name="csrf-token"]');
  return meta ? meta.getAttribute("content") : "";
}

async function apiCall(url, method, body) {
  const options = {
    method,
    credentials: "same-origin",
    headers: { Accept: "application/json", "X-CSRF-Token": csrfToken() },
  };
  if (body != null) {
    options.headers["Content-Type"] = "application/json";
    options.body = JSON.stringify(body);
  }
  const res = await fetch(url, options);
  if (!res.ok) throw new Error(`http_${res.status}`);
  if (res.status === 204) return null;
  return res.json();
}

// Whether this message is still waiting on the person, and which renderer
// answers it. An expired, submitted or already-superseded one is history:
// the server refuses it anyway, and showing it would park a dead form over
// the buttons forever.
function liveAsk(message) {
  const meta = message?.metadata || {};
  if (!ASK_TOOLS.has(meta.tool_name)) return null;

  // The same two facts the server refuses a tap on. Without them a decided or
  // expired action still looked like a question, and since this covers the
  // buttons, one of those parked itself over them permanently — every tap
  // coming back "couldn't do that just now".
  if (meta.action_state === "decided") return null;
  const expiresAt = meta.action_expires_at
    ? Date.parse(meta.action_expires_at)
    : NaN;
  if (Number.isFinite(expiresAt) && Date.now() > expiresAt) return null;

  if (meta.tool_name === "buddy_form") {
    if (!Array.isArray(meta.form?.fields)) return null;
    const status = meta.form.status;
    return status === "submitted" || status === "superseded" ? null : "form";
  }

  if (!meta.multi_select) return null;
  const buttons = Array.isArray(meta.buttons) ? meta.buttons : [];
  const open = buttons.some((b) => (b.status || "pending") === "pending");
  return open ? "buttons" : null;
}

// The words, with the side-effect markers taken out. A message that is only a
// streaming placeholder isn't anything to show yet — the pet is already
// wearing the thinking face, which says the same thing better.
function speakable(message) {
  if (!message || message.direction !== "inbound") return "";
  if (message.metadata?.hidden === true) return "";

  const body = String(message.body || "");
  const stripped = body.replace(/\[\[[^\]]*\]\]/g, "").trim();
  if (!stripped || /^[.…]+$/.test(stripped)) return "";
  return body;
}

export function initBuddyKiosk({
  root,
  conversationIdFn,
  conversationsFn,
  themes,
  switchTo,
  renderMarkdown,
} = {}) {
  if (!root) return null;

  const sayEl = root.querySelector("[data-kiosk-say]");
  const padEl = root.querySelector("[data-kiosk-pad]");
  const askEl = root.querySelector("[data-kiosk-ask]");
  const askBodyEl = root.querySelector("[data-kiosk-ask-body]");
  const askCloseEl = root.querySelector("[data-kiosk-ask-close]");
  const whoEl = root.querySelector("[data-kiosk-who]");
  const pickerEl = root.querySelector("[data-kiosk-picker]");
  const pickListEl = root.querySelector("[data-kiosk-picker-list]");

  let sayFadeTimer = 0;
  let sayHideTimer = 0;
  // Which message the card is currently answering, so an update to THAT
  // message (the server re-broadcasts it on submit) closes the card, while an
  // update to any other one leaves it alone.
  let askingMessageId = null;
  // Questions put away by hand. They stay away: the × means "not this", and a
  // reconnect or a re-broadcast dragging one back over the buttons would make
  // the button useless.
  const dismissed = new Set();

  // ---- what the pet just said ----

  function say(message) {
    const text = speakable(message);
    if (!sayEl || !text) return;

    window.clearTimeout(sayFadeTimer);
    window.clearTimeout(sayHideTimer);

    if (renderMarkdown) sayEl.innerHTML = renderMarkdown(text);
    else sayEl.textContent = text;
    sayEl.hidden = false;
    sayEl.dataset.fading = "false";
    sayEl.scrollTop = 0;

    const hold = Math.min(
      SAY_BASE_MS + text.length * SAY_PER_CHAR_MS,
      SAY_MAX_MS,
    );
    sayFadeTimer = window.setTimeout(() => {
      sayEl.dataset.fading = "true";
      sayHideTimer = window.setTimeout(() => {
        sayEl.hidden = true;
      }, SAY_FADE_MS);
    }, hold);
  }

  // ---- a question, over the buttons ----

  // Rebuilt only when the question CHANGES. An update to the one already up
  // re-renders into the same mount, because renderForm refuses to rebuild
  // under someone's cursor — and tearing the container out from under it would
  // take the caret, and the half-typed answer, with it.
  function showAsk(message, shape) {
    if (!askEl || !askBodyEl) return;
    if (dismissed.has(message.id)) return;

    if (message.id == null || message.id !== askingMessageId) {
      askBodyEl.innerHTML = "";
      askingMessageId = message.id;

      // Buddy's own words above the controls. A bare form with no lead-in
      // reads as a system prompt rather than something the pet asked.
      const prose = speakable(message);
      if (prose) {
        const text = document.createElement("p");
        text.className = "byte-kiosk-ask-text";
        if (renderMarkdown) text.innerHTML = renderMarkdown(prose);
        else text.textContent = prose;
        askBodyEl.appendChild(text);
      }

      const mount = document.createElement("div");
      mount.dataset.kioskAskMount = "";
      askBodyEl.appendChild(mount);
      askEl.hidden = false;
      askEl.scrollTop = 0;
    }

    const mount = askBodyEl.querySelector("[data-kiosk-ask-mount]");
    if (!mount) return;
    if (shape === "form") renderForm(mount, message);
    else renderMultiSelect(mount, message);
  }

  function clearAsk() {
    askingMessageId = null;
    if (!askEl) return;
    askEl.hidden = true;
    if (askBodyEl) askBodyEl.innerHTML = "";
  }

  askCloseEl?.addEventListener("click", () => {
    if (askingMessageId != null) dismissed.add(askingMessageId);
    clearAsk();
  });

  // ---- the buttons ----

  function paintPad(routines) {
    if (!padEl) return;

    padEl.innerHTML = "";
    if (routines.length === 0) {
      const empty = document.createElement("p");
      empty.className = "byte-kiosk-empty";
      empty.textContent = NO_ROUTINES;
      padEl.appendChild(empty);
      return;
    }

    routines.forEach((routine) => {
      const btn = document.createElement("button");
      btn.type = "button";
      btn.className = "byte-kiosk-btn";
      btn.dataset.kioskRoutine = String(routine.id);

      const name = document.createElement("span");
      name.className = "byte-kiosk-btn-name";
      name.textContent = routine.name;
      btn.appendChild(name);

      if (routine.description) {
        const sub = document.createElement("span");
        sub.className = "byte-kiosk-btn-sub";
        sub.textContent = routine.description;
        btn.appendChild(sub);
      }

      padEl.appendChild(btn);
    });
  }

  // The pad is server-rendered for first paint (a cold boot off the cached
  // shell has its buttons immediately), and this is what keeps it honest —
  // pinning something on a phone shows up here without anyone reloading.
  async function refresh() {
    try {
      const data = await apiCall(ROUTINES_URL, "GET");
      paintPad(quickOrder(data?.routines));
    } catch (e) {
      // Leave whatever's on screen. The buttons that are already there still
      // work, and a wall tablet that blanks its own controls on a blip is
      // worse than one showing a slightly stale set.
    }
  }

  async function run(btn) {
    const conversationId = conversationIdFn ? conversationIdFn() : null;
    if (conversationId == null) return;

    btn.dataset.running = "true";
    try {
      await apiCall(`${ROUTINES_URL}/${btn.dataset.kioskRoutine}/run`, "POST", {
        conversation_id: conversationId,
      });
    } catch (e) {
      // The steps post their own receipts, so a failure here is a failure to
      // even start — say so, since nothing else will.
      say({ direction: "inbound", body: "Couldn't start that one just now." });
    } finally {
      delete btn.dataset.running;
    }
  }

  if (padEl) {
    padEl.addEventListener("click", (e) => {
      const btn = e.target.closest("[data-kiosk-routine]");
      if (btn) run(btn);
    });
  }

  // ---- which companion is out here ----

  // A thread and a companion are the same choice: the theme on the row decides
  // the character, the name, the palette, and the voice it answers in. So this
  // lists threads and shows them as their pets.
  function paintPicker() {
    if (!pickListEl) return;

    const current = conversationIdFn ? conversationIdFn() : null;
    const list = (conversationsFn ? conversationsFn() : []) || [];

    pickListEl.innerHTML = "";
    list.forEach((convo) => {
      if (convo.mode !== "buddy") return;

      const chrome = (themes || {})[convo.buddy_theme] || {};
      const row = document.createElement("button");
      row.type = "button";
      row.className = "byte-kiosk-pick";
      row.dataset.kioskPick = String(convo.id);
      row.setAttribute("aria-current", String(convo.id === current));

      if (chrome.avatar) {
        const img = document.createElement("img");
        img.src = chrome.avatar;
        img.alt = "";
        row.appendChild(img);
      }

      const text = document.createElement("span");
      text.className = "byte-kiosk-pick-text";
      const pet = document.createElement("span");
      pet.className = "byte-kiosk-pick-pet";
      pet.textContent = convo.buddy_name || chrome.name || "Buddy";
      text.appendChild(pet);
      // Several threads can wear the same companion, so the thread's own name
      // is what tells two Sukis apart.
      if (convo.name && convo.name !== pet.textContent) {
        const thread = document.createElement("span");
        thread.className = "byte-kiosk-pick-thread";
        thread.textContent = convo.name;
        text.appendChild(thread);
      }
      row.appendChild(text);

      pickListEl.appendChild(row);
    });
  }

  function openPicker() {
    if (!pickerEl) return;
    paintPicker();
    pickerEl.hidden = false;
    whoEl?.setAttribute("aria-expanded", "true");
  }

  function closePicker() {
    if (!pickerEl) return;
    pickerEl.hidden = true;
    whoEl?.setAttribute("aria-expanded", "false");
  }

  // Switch now, and remember it. The switch is client-side because the page
  // already knows how to repaint a thread's whole identity, and reloading
  // would come back off the cached shell still wearing the old pet. The POST
  // is what makes the next COLD boot render this one server-side, with no
  // first-paint flash of whoever was here before.
  async function pick(id) {
    closePicker();
    clearAsk();
    switchTo?.(Number(id));
    try {
      await apiCall(PIN_URL, "POST", { conversation_id: Number(id) });
    } catch (e) {
      // The screen is already showing the right companion; all that's lost is
      // it surviving a restart, and picking again fixes that.
    }
  }

  if (whoEl) {
    whoEl.setAttribute("aria-expanded", "false");
    whoEl.addEventListener("click", () => {
      if (pickerEl?.hidden) openPicker();
      else closePicker();
    });
  }

  if (pickerEl) {
    pickerEl.addEventListener("click", (e) => {
      const row = e.target.closest("[data-kiosk-pick]");
      if (row) pick(row.dataset.kioskPick);
    });

    document.addEventListener("click", (e) => {
      if (pickerEl.hidden) return;
      if (pickerEl.contains(e.target) || whoEl?.contains(e.target)) return;
      closePicker();
    });
  }

  // A tablet left on a wall sits idle for hours. Re-reading the pinned set
  // when it wakes costs one request and catches everything that changed while
  // nobody was looking at it.
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") refresh();
  });

  refresh();

  return {
    // A message that just arrived over the socket.
    onLive(message) {
      if (!message) return;

      const shape = liveAsk(message);
      if (shape) return showAsk(message, shape);

      // The card's own message came back changed — answered, expired, or
      // replaced by a corrected one. Taking it down IS the acknowledgement;
      // reading the question back as a bubble a beat after answering it isn't.
      if (message.id != null && message.id === askingMessageId) {
        return clearAsk();
      }

      say(message);
    },

    // A whole list, from boot or a history refetch. Silent by design: a reload
    // shouldn't replay something said an hour ago.
    //
    // Only a FORM comes back, and the difference matters because this covers
    // the buttons. A form is something a sequence is STUCK on — nothing more
    // happens until it's answered, so it has to return or the run is stranded.
    // A checklist is an offer, and ignoring one is a valid answer; an hour-old
    // one owning the wall is worse than not seeing it at all.
    sync(messages) {
      const list = Array.isArray(messages) ? messages : [];

      // Leave a live card alone. A refetch fires on reconnect and on every
      // return to the foreground, and it must not clear a checklist that just
      // arrived and is waiting on a tap.
      const stillLive = list.some(
        (m) => m.id === askingMessageId && liveAsk(m),
      );
      if (askingMessageId != null && stillLive) return;

      for (let i = list.length - 1; i >= 0; i--) {
        if (liveAsk(list[i]) === "form") return showAsk(list[i], "form");
      }
      clearAsk();
    },

    refresh,
  };
}
