// Slash-command autocomplete for the Byte composer.
//
// UX: as soon as the composer's first character is "/", a popover
// appears above the input with the list of available commands.
// Fuzzy-filtered by whatever the user has typed after the slash.
// Tap (or Enter with a highlighted row) inserts the command and
// positions the cursor so args can be typed immediately.
//
// The command list is client-side and hardcoded — commands are stable
// enough (~15 total) that a server round-trip would just add latency
// without buying anything. Order here roughly matches the /help output
// so the popover feels familiar next to that.
//
// Two-priority match:
//   1. Prefix match on the command name  (highest)
//   2. Substring match on the description (lowest)
// With an empty query, everything shows in list order.

const COMMANDS = [
  // Claude sessions
  { name: "sessions", description: "Recent Claude sessions in this cwd" },
  { name: "switch",   description: "Resume a Claude session",           args: "<n|name|prefix>" },
  { name: "adopt",    description: "Attach this conversation to an existing session", args: "<name>" },
  { name: "join",     description: "Alias for /adopt — join a session", args: "<name>" },
  { name: "new",      description: "Clear Claude session — next msg starts fresh" },
  { name: "watch",    description: "Ping when a session next stops / prompts",         args: "[name]" },
  { name: "unwatch",  description: "Stop watching a session",                          args: "[name]" },
  { name: "watches",  description: "List sessions this thread is watching" },

  // Background tasks
  { name: "wait",     description: "Kick off a background task; ping when done",       args: "<preset|cmd>" },
  { name: "waits",    description: "List running waits" },

  // Buddy mode
  { name: "tools",    description: "Buddy tool access (on default | off | list)",     args: "[spec]" },

  // Conversation
  { name: "rename",   description: "Rename this conversation",                         args: "<new name>" },
  { name: "archive",  description: "Archive this conversation" },
  { name: "mode",     description: "Change dispatch mode",                             args: "<claude|bash|jarvis|buddy>" },
  { name: "fork",     description: "Fork this conversation into a new one" },

  // Shell / utility
  { name: "abort",    description: "Cancel a running shell command" },
  { name: "pwd",      description: "Show current working directory" },
  { name: "clear",    description: "(client-only) wipe local queue + cache" },
  { name: "help",     description: "Show all slash commands" },
];

// Wire up the popover. Called once at boot from index.js.
//   options.input     — the <textarea> element (must have `data-byte-input`)
//   options.popover   — the popover container element
//   options.autosize  — the composer's autosize() to call after inserts
export function setupSlashAutocomplete({ input, popover, autosize }) {
  if (!input || !popover) return;

  let visible   = false;
  let filtered  = COMMANDS.slice();
  let highlight = 0;

  const render = () => {
    if (filtered.length === 0) {
      popover.innerHTML = `<div class="byte-slash-empty">No matching commands.</div>`;
      return;
    }
    popover.innerHTML = filtered.map((c, i) => {
      const active = i === highlight ? " byte-slash-row-active" : "";
      const args = c.args ? `<span class="byte-slash-args">${escapeHtml(c.args)}</span>` : "";
      return `
        <button type="button" class="byte-slash-row${active}" data-byte-slash-name="${escapeAttr(c.name)}" data-byte-slash-args="${escapeAttr(c.args || "")}" role="option">
          <span class="byte-slash-name">/${escapeHtml(c.name)}</span>
          ${args}
          <span class="byte-slash-desc">${escapeHtml(c.description)}</span>
        </button>
      `;
    }).join("");

    // Ensure the highlighted row is visible in the scrollable list.
    const active = popover.querySelector(".byte-slash-row-active");
    if (active) {
      const r = active.getBoundingClientRect();
      const p = popover.getBoundingClientRect();
      if (r.bottom > p.bottom) popover.scrollTop += r.bottom - p.bottom;
      else if (r.top < p.top)  popover.scrollTop -= p.top - r.top;
    }
  };

  const show = () => {
    if (visible) return;
    popover.hidden = false;
    visible = true;
    render();
  };

  const hide = () => {
    if (!visible) return;
    popover.hidden = true;
    visible = false;
    highlight = 0;
  };

  // Given the current input value, decide whether to show the popover
  // and rebuild the filtered list. Only fires when the text STARTS with
  // "/" AND the user is still typing the verb (no whitespace yet). Once
  // they type a space they've moved into argument territory, at which
  // point the popover is just noise blocking the actual composer view.
  const refresh = () => {
    const v = input.value || "";
    if (!v.startsWith("/")) { hide(); return; }
    const rest = v.slice(1);
    // Past the verb (whitespace present) → hide. User is typing args now.
    if (/\s/.test(rest)) { hide(); return; }
    filtered = filter(rest.toLowerCase());
    highlight = 0;
    show();
  };

  // Insert a command into the composer. Cursor lands after the command
  // (before any args) so the user can immediately type the argument.
  const insert = (cmd) => {
    const val = `/${cmd.name}${cmd.args ? " " : ""}`;
    input.value = val;
    autosize?.();
    try {
      const end = val.length;
      input.setSelectionRange(end, end);
    } catch (_) {}
    input.focus();
    hide();
  };

  input.addEventListener("input", refresh);
  input.addEventListener("focus", refresh);

  input.addEventListener("keydown", (e) => {
    if (!visible) return;
    if (e.key === "Escape") {
      hide();
      e.stopPropagation();
      return;
    }
    if (e.key === "ArrowDown") {
      e.preventDefault();
      highlight = Math.min(highlight + 1, filtered.length - 1);
      render();
      return;
    }
    if (e.key === "ArrowUp") {
      e.preventDefault();
      highlight = Math.max(highlight - 1, 0);
      render();
      return;
    }
    if (e.key === "Tab" || (e.key === "Enter" && !e.shiftKey && filtered[highlight])) {
      // Tab always completes; Enter completes only when the input is
      // still just the verb (no args typed yet) — once the user is
      // typing args, Enter should send the message.
      const stillOnlyVerb = !/\s/.test(input.value.slice(1));
      if (e.key === "Tab" || stillOnlyVerb) {
        e.preventDefault();
        // stopImmediatePropagation so the composer's own keydown handler
        // (attached later in index.js) doesn't ALSO fire and send the
        // just-completed command as a message.
        e.stopImmediatePropagation();
        insert(filtered[highlight]);
      }
    }
  });

  // Tap-to-insert. Use mousedown/touchstart so the input doesn't lose
  // focus (which would fire blur → hide → click never lands).
  popover.addEventListener("mousedown", (e) => {
    const row = e.target.closest?.("[data-byte-slash-name]");
    if (!row) return;
    e.preventDefault();
    insert({
      name: row.dataset.byteSlashName,
      args: row.dataset.byteSlashArgs || "",
    });
  });

  // Hide when the user taps outside the popover / input.
  document.addEventListener("mousedown", (e) => {
    if (!visible) return;
    if (e.target === input) return;
    if (popover.contains(e.target)) return;
    hide();
  });

  // Also hide when the input is emptied or when its first char stops
  // being "/" (e.g., user backspaced past the slash).
  input.addEventListener("blur", () => {
    // small delay so a popover tap can still land before we hide
    setTimeout(hide, 120);
  });
}

// Name-only match. Description-substring matching was so permissive
// that typing a common letter (like "t") barely narrowed the list -
// almost every command had "t" somewhere in its description, so the
// popover felt unresponsive. Prefix match ranks above substring match.
function filter(query) {
  if (!query) return COMMANDS.slice();
  return COMMANDS
    .map((c) => {
      let score = 0;
      if (c.name.startsWith(query))     score = 100;
      else if (c.name.includes(query))  score = 50;
      return { c, score };
    })
    .filter((x) => x.score > 0)
    .sort((a, b) => b.score - a.score)
    .map((x) => x.c);
}

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}
function escapeAttr(s) { return escapeHtml(s).replace(/"/g, "&quot;"); }
