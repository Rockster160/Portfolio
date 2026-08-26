// Slash-command autocomplete for the Byte composer.
//
// UX: as soon as the composer's first character is "/", a popover
// appears above the input with the list of available commands.
// Fuzzy-filtered by whatever the user has typed after the slash.
// Tap (or Enter with a highlighted row) inserts the command and
// positions the cursor so args can be typed immediately.
//
// The command list is client-side and hardcoded — commands are stable
// enough (~20 total) that a server round-trip would just add latency
// without buying anything. Order here roughly matches the /help output
// so the popover feels familiar next to that.
//
// Two-priority match:
//   1. Prefix match on the command name  (highest)
//   2. Substring match on the description (lowest)
// With an empty query, everything shows in list order.
//
// `modes` is which conversation modes a command actually does something in;
// absent means all of them. `owner` marks the ones only the Mac's owner can
// use. Both are about not OFFERING something that would only fail — the server
// refuses each of these on its own (ByteController#handle_rails_slash_command
// for the Rails-owned ones, ByteMessageIntake#locked_out? for the Mac handoff),
// so this list is presentation, never the gate.

// Commands the Mac's meta handler owns. Only claude, bash and cursor threads
// reach it — jarvis dispatches to ByteJarvisWorker and buddy never leaves Rails
// — so offering these anywhere else is offering a no-op.
const MAC_MODES = ["claude", "bash", "cursor"];

const COMMANDS = [
  // Claude sessions
  { name: "sessions", modes: MAC_MODES, description: "Recent Claude sessions in this cwd" },
  { name: "switch",   modes: MAC_MODES, description: "Resume a Claude session",           args: "<n|name|prefix>" },
  { name: "adopt",    modes: MAC_MODES, description: "Attach this conversation to an existing session", args: "<name>" },
  { name: "join",     modes: MAC_MODES, alias: true, description: "Alias for /adopt — join a session", args: "<name>" },
  { name: "new",      modes: MAC_MODES, description: "Clear Claude session — next msg starts fresh" },
  { name: "watch",    modes: MAC_MODES, description: "Ping when a session next stops / prompts",         args: "[name]" },
  { name: "unwatch",  modes: MAC_MODES, description: "Stop watching a session",                          args: "[name]" },
  { name: "watches",  modes: MAC_MODES, description: "List sessions this thread is watching" },

  // Background tasks
  { name: "wait",     modes: MAC_MODES, description: "Kick off a background task; ping when done",       args: "<preset|cmd>" },
  { name: "waits",    modes: MAC_MODES, description: "List running waits" },

  // Buddy mode
  { name: "today",    modes: ["buddy"], description: "Send the Today briefing now" },
  { name: "buddy",    modes: ["buddy"], description: "Switch this thread's pet",                         args: "<byte|moss|suki|glimmer>" },
  { name: "reset",    modes: ["buddy"], description: "Fresh start here — stop sending everything above as history" },
  { name: "compact",  modes: ["buddy"], alias: true, description: "Alias for /reset" },

  // Jarvis. Everywhere, because the house doesn't care which thread you're
  // standing in — the bare-dot shortcut for the same thing is Buddy-only.
  { name: "jarvis",   owner: true, description: "Say this to Jarvis",                  args: "<command>" },
  { name: "j",        owner: true, alias: true, description: "Alias for /jarvis",      args: "<command>" },

  // Conversation
  { name: "rename",   description: "Rename this conversation",                         args: "<new name>" },
  { name: "archive",  description: "Archive this conversation" },
  { name: "mode",     owner: true, description: "Change dispatch mode",                 args: "<claude|cursor|bash|jarvis|buddy>" },
  { name: "fork",     description: "Fork this conversation into a new one" },

  // Shell / utility
  { name: "abort",    modes: MAC_MODES, description: "Cancel a running shell command" },
  { name: "pwd",      modes: MAC_MODES, description: "Show current working directory" },
  // Rails-owned, unlike the Mac's `!cd`: it writes the conversation record, so
  // it works on a thread that has never run anything and survives the Mac
  // being asleep.
  { name: "cd",       modes: MAC_MODES, description: "Set this thread's working directory", args: "<path>" },
  { name: "clear",    description: "(client-only) wipe local queue + cache" },
  { name: "help",     modes: MAC_MODES, description: "Show all slash commands" },
];

// The commands that mean something for the thread on screen. Mode does nearly
// all the narrowing: a Buddy thread has no Claude session to resume and no
// shell to abort, which takes 21 down to 7 for the owner and 6 for everyone
// else (only /mode is owner-only).
//
// `alias` entries are real commands and stay matchable — typing `/compact`
// still finds it — they just don't take up a row in the browse list next to
// the name they're an alias for.
export function available({ mode, owner }) {
  return COMMANDS.filter((c) => {
    if (c.owner && !owner) return false;
    return !c.modes || c.modes.includes(mode);
  });
}

// Wire up the popover. Called once at boot from index.js.
//   options.input     — the <textarea> element (must have `data-byte-input`)
//   options.popover   — the popover container element
//   options.autosize  — the composer's autosize() to call after inserts
//   options.app       — the `.byte-app` element, read for the live mode + owner
export function setupSlashAutocomplete({ input, popover, autosize, app }) {
  if (!input || !popover) return;

  // Read at filter time rather than captured at boot: `data-active-mode` is
  // repointed on every conversation switch, so switching into a Buddy thread
  // narrows the list with no re-wiring.
  const context = () => ({
    mode: app?.dataset.activeMode,
    owner: app?.dataset.byteOwner === "true",
  });

  let visible   = false;
  let filtered  = filter("", context());
  let highlight = 0;

  const render = () => {
    if (filtered.length === 0) {
      // In a Buddy thread a dot in front of something we don't know isn't a
      // miss — it's a command on its way to Jarvis, and saying so is how that
      // routing is discoverable at all ("No matching commands" read as a dead
      // end). Anywhere else the dot is only ever a slash-command alias, so the
      // dead end is the truth and `/j` is the way to the house.
      const { mode, owner } = context();
      popover.innerHTML =
        activePrefix === "." && mode === "buddy" && owner
          ? `<div class="byte-slash-empty">Goes straight to Jarvis.</div>`
          : `<div class="byte-slash-empty">No matching commands.</div>`;
      return;
    }
    popover.innerHTML = filtered.map((c, i) => {
      const active = i === highlight ? " byte-slash-row-active" : "";
      const args = c.args ? `<span class="byte-slash-args">${escapeHtml(c.args)}</span>` : "";
      return `
        <button type="button" class="byte-slash-row${active}" data-byte-slash-name="${escapeAttr(c.name)}" data-byte-slash-args="${escapeAttr(c.args || "")}" role="option">
          <span class="byte-slash-name">${activePrefix}${escapeHtml(c.name)}</span>
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
    // Always render on show(). The old `if (visible) return` guard
    // meant the DOM was only populated on the first / keystroke; every
    // subsequent character updated `filtered` in memory but skipped
    // render(), so the popover kept showing the initial full list even
    // as the user narrowed the query. Idempotent on the flip; render()
    // is a single innerHTML replace, cheap.
    if (!visible) {
      popover.hidden = false;
      visible = true;
    }
    render();
  };

  const hide = () => {
    if (!visible) return;
    popover.hidden = true;
    visible = false;
    highlight = 0;
  };

  // Which prefix the user is currently typing (either "/" or "."). Both
  // trigger the popover and dispatch identically server-side; we remember
  // which one to preserve on insert so a `.new` completion doesn't
  // silently flip to `/new` mid-type.
  let activePrefix = "/";

  const prefixOf = (v) => {
    if (v.startsWith("/")) return "/";
    if (v.startsWith(".")) return ".";
    return null;
  };

  // Given the current input value, decide whether to show the popover
  // and rebuild the filtered list. Only fires when the text STARTS with
  // a slash-command prefix ("/" or ".") AND the user is still typing the
  // verb (no whitespace yet). Once they type a space they've moved into
  // argument territory, at which point the popover is just noise blocking
  // the actual composer view.
  const refresh = () => {
    const v = input.value || "";
    const p = prefixOf(v);
    if (!p) { hide(); return; }
    activePrefix = p;
    const rest = v.slice(1);
    // Past the verb (whitespace present) → hide. User is typing args now.
    if (/\s/.test(rest)) { hide(); return; }
    filtered = filter(rest.toLowerCase(), context());
    highlight = 0;
    show();
  };

  // Insert a command into the composer. Cursor lands after the command
  // (before any args) so the user can immediately type the argument.
  // Uses whichever prefix the user was typing.
  const insert = (cmd) => {
    const val = `${activePrefix}${cmd.name}${cmd.args ? " " : ""}`;
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
    // Both need something to complete TO. Tab used not to check, and with a
    // dot now able to precede any words at all, `insert(undefined)` went from
    // unreachable to one keystroke away.
    if (!filtered[highlight]) return;
    if (e.key === "Tab" || (e.key === "Enter" && !e.shiftKey)) {
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
function filter(query, ctx) {
  const pool = available(ctx);
  if (!query) return pool.filter((c) => !c.alias);
  return pool
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
