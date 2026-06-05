// Edit / Create Timer modal. Reused for: new timer, edit existing timer,
// AND for authoring a Quick / Saved button template (mode === "quick").

import {
  parseDuration,
  defaultLabelForSeconds,
  humanizeSeconds,
} from "./duration";
import { CHIME_NAMES, CADENCE_OPTIONS, previewChime } from "./audio";

export function setupEditModal({ root, store, actions, activePageId }) {
  const dialog = root.querySelector("[data-timers-edit-modal]");
  if (!dialog) return { open: () => {} };

  const form = dialog.querySelector("[data-timers-edit-form]");
  const titleEl = dialog.querySelector("[data-timers-edit-title]");
  const deleteBtn = dialog.querySelector("[data-timers-delete]");
  const templateBtn = dialog.querySelector("[data-timers-save-as-template]");
  const callbacksList = dialog.querySelector("[data-timers-callbacks-list]");
  const kindFieldsets = dialog.querySelectorAll("[data-when-kind]");
  const timerOnly = dialog.querySelectorAll('[data-when-mode="timer"]');
  const quickOnly = dialog.querySelectorAll('[data-when-mode="quick"]');
  const pageSelect = form.querySelector('[data-timers-field="timer_page_id"]');
  const labelInput = form.querySelector('[data-timers-field="quick_label"]');
  const durationInput = form.querySelector(
    '[data-timers-field="duration_text"]',
  );
  const durationPreview = form.querySelector("[data-timers-duration-preview]");

  let mode = "timer"; // "timer" | "quick"
  let editingId = null;
  let editingQuickIsPinned = true;
  let onSaveQuick = null;

  function field(name) {
    return form.querySelector(`[data-timers-field="${name}"]`);
  }

  function setKindVisibility(kind) {
    kindFieldsets.forEach((fs) => {
      fs.hidden = fs.dataset.whenKind !== kind;
    });
    updateDurationPreview();
  }

  function setModeVisibility() {
    // Don't rely on the `hidden` attribute alone — the global `.field`
    // rule sets `display: flex` which overrides it (the hidden-attr
    // pitfall). Toggle the `.hidden` class too, which carries the
    // `display: none !important` global override.
    timerOnly.forEach((el) => {
      el.hidden = mode !== "timer";
      el.classList.toggle("hidden", mode !== "timer");
    });
    quickOnly.forEach((el) => {
      el.hidden = mode !== "quick";
      el.classList.toggle("hidden", mode !== "quick");
    });
  }

  function refreshPageOptions(selectedId) {
    pageSelect.innerHTML = '<option value="">Home</option>';
    Array.from(store.pages.values())
      .sort((a, b) => (a.sort_order || 0) - (b.sort_order || 0))
      .forEach((p) => {
        const opt = document.createElement("option");
        opt.value = String(p.id);
        opt.textContent = p.name || p.slug;
        if (selectedId != null && Number(selectedId) === p.id)
          opt.selected = true;
        pageSelect.appendChild(opt);
      });
  }

  function updateDurationPreview() {
    if (!durationPreview || !durationInput) return;
    if (field("kind").value !== "countdown") {
      durationPreview.textContent = "";
      return;
    }
    const v = durationInput.value;
    if (!v.trim()) {
      durationPreview.textContent = "";
      durationPreview.classList.remove("is-invalid");
      return;
    }
    const secs = parseDuration(v);
    const human = humanizeSeconds(secs);
    if (secs == null || !human) {
      durationPreview.textContent =
        "Couldn't parse — try 5m, 4:30, 1h30m, 90s, or just 30 for seconds";
      durationPreview.classList.add("is-invalid");
    } else {
      durationPreview.textContent = human;
      durationPreview.classList.remove("is-invalid");
    }
  }

  function setFields(t) {
    field("kind").value = t.kind || "countdown";
    field("name").value = t.name || "";
    // Show the fallback identifier as the placeholder when the timer
    // already exists, so the user can see what it's called in dropdowns
    // without being forced to set a name.
    if (t.id) field("name").placeholder = timerPlaceholderName(t);
    field("color").value = t.color || "#388BFD";

    field("duration_text").value = t.duration_ms
      ? defaultLabelForSeconds(Math.round(t.duration_ms / 1000))
      : "5m";
    field("repeat").checked = !!t.repeat;
    field("disabled").checked = !!t.disabled;

    field("value").value = t.value ?? 0;
    field("step").value = t.step ?? 1;
    field("min_value").value = t.min_value ?? 0;
    field("max_value").value = t.max_value ?? 10;

    field("dial_text").value = dialConfigToText(t.dial_config);
    field("dial_start_offset").value = Number(t.dial_config?.start_offset) || 0;

    refreshPageOptions(t.timer_page_id ?? activePageId());

    callbacksList.innerHTML = "";
    (t.callbacks || []).forEach((cb) =>
      appendCallbackRow(upgradeLegacyCallback(cb)),
    );

    setKindVisibility(t.kind || "countdown");
  }

  function dialConfigToText(cfg) {
    if (!cfg?.sections || cfg.sections.length === 0) {
      return "Setup\nActions *2 #3fb950: Move, Attack #f85149, Loot #58a6ff\nCleanup";
    }
    return cfg.sections
      .map((sec) => {
        const weight = Number(sec.weight) > 1 ? ` *${sec.weight}` : "";
        const color  = sec.color ? ` ${sec.color}` : "";
        const head = `${sec.name || ""}${weight}${color}`;
        const subs = (sec.subs || [])
          .map((s) => {
            if (typeof s === "string") return s;
            const sc = s.color ? ` ${s.color}` : "";
            return `${s.name || ""}${sc}`;
          })
          .join(", ");
        return subs ? `${head}: ${subs}` : head;
      })
      .join("\n");
  }

  // Pulls `*N` (weight) and `#hex` (color) tokens out of a head/sub
  // fragment, returning {name, weight?, color?}. Tokens can appear in
  // any order; whatever's left becomes the name. Hex accepts 3/4/6/8
  // digits. Lowercase the hex on parse so the round-trip is stable.
  function parseDialTokens(raw) {
    let weight = null;
    let color = null;
    const name = String(raw || "")
      .replace(/\*\s*(\d+(?:\.\d+)?)/g, (_, w) => { weight = parseFloat(w); return " "; })
      .replace(/#([0-9a-f]{3,8})\b/i, (_, hex) => { color = `#${hex.toLowerCase()}`; return " "; })
      .replace(/\s+/g, " ")
      .trim();
    return { name, weight, color };
  }

  function textToDialConfig(text) {
    // Per-line grammar:  Name [*Weight] [#color] [: sub[, sub]...]
    //   - "Setup"                          → weight 1, no color, no subs
    //   - "Setup *2"                       → weight 2
    //   - "Setup #ff0000"                  → color red
    //   - "Setup *2 #ff0000"               → both
    //   - "Combat #f00: Attack #ff0, Defend #0f0"   → section + sub colors
    // Tokens can appear in any order; the name is whatever's left.
    const lines = String(text || "")
      .split("\n")
      .map((l) => l.trim())
      .filter(Boolean);
    return {
      sections: lines.map((line) => {
        const colonIdx = line.indexOf(":");
        const head = colonIdx === -1 ? line : line.slice(0, colonIdx);
        const tail = colonIdx === -1 ? "" : line.slice(colonIdx + 1);
        const { name, weight, color } = parseDialTokens(head);

        const subs = tail
          .split(",")
          .map((p) => p.trim())
          .filter(Boolean)
          .map((p) => {
            const parsed = parseDialTokens(p);
            return parsed.color ? { name: parsed.name, color: parsed.color } : parsed.name;
          });

        const section = { name, subs };
        if (Number.isFinite(weight) && weight > 0) section.weight = weight;
        if (color) section.color = color;
        return section;
      }),
    };
  }

  function readForm() {
    const kind = field("kind").value;
    const payload = {
      kind,
      name: field("name").value.trim(),
      color: field("color").value || null,
      callbacks: readCallbacks(),
    };
    if (mode === "timer") {
      const pageVal = pageSelect.value;
      payload.timer_page_id = pageVal === "" ? null : parseInt(pageVal, 10);
      payload.disabled = field("disabled").checked;
    }
    if (kind === "countdown") {
      const seconds = parseDuration(field("duration_text").value);
      payload.duration_ms = (seconds && seconds > 0 ? seconds : 60) * 1000;
      payload.repeat = field("repeat").checked;
    } else if (kind === "counter") {
      payload.value = parseInt(field("value").value, 10) || 0;
      payload.step = Math.max(1, parseInt(field("step").value, 10) || 1);
      payload.min_value = parseIntOrNull(field("min_value").value);
      payload.max_value = parseIntOrNull(field("max_value").value);
      payload.reset_value = payload.value;
    } else if (kind === "dial") {
      payload.dial_config = textToDialConfig(field("dial_text").value);
      const rawOff = parseFloat(field("dial_start_offset").value);
      payload.dial_config.start_offset = Number.isFinite(rawOff) ? rawOff : 0;
      payload.dial_step_index = 0;
    }
    return payload;
  }

  function parseIntOrNull(v) {
    const s = String(v ?? "").trim();
    if (s === "") return null;
    const n = parseInt(s, 10);
    return Number.isNaN(n) ? null : n;
  }

  // =========================
  // Callback editor — each row is one (when, then) pair.
  //
  // Row shape:
  //   { id, when: { type, ...args }, then: { type, ...args } }
  //
  // Both halves render their own dropdown + an args panel. The args
  // panel repaints on type change without nuking the other half's
  // values (we snapshot via readRow before repainting).
  // =========================

  // Each entry maps to a set of `kinds` it's available for. Filtering
  // in renderCallbackRow trims the dropdown to options that actually
  // apply to the timer being edited, so a Dial editor never offers
  // "Countdown reaches…" and vice versa.
  const WHEN_TYPES = [
    {
      value: "complete",
      label: "Timer completes",
      kinds: ["countdown", "counter", "dial"],
    },
    { value: "confirm", label: "User confirms", kinds: ["countdown"] },
    {
      value: "countdown_at",
      label: "Countdown reaches…",
      kinds: ["countdown"],
    },
    {
      value: "counter_reaches",
      label: "Counter hits a value…",
      kinds: ["counter"],
    },
    { value: "dial_step", label: "Dial reaches step…", kinds: ["dial"] },
  ];

  const THEN_TYPES = [
    { value: "sound", label: "🎵 Sound" },
    { value: "push", label: "🔔 Notification" },
    { value: "jil", label: "⚡ Jil" },
    { value: "chain", label: "🔗 Timer" },
  ];

  const CHAIN_OPS = [
    { value: "start", label: "Start" },
    { value: "pause", label: "Pause" },
    { value: "resume", label: "Resume" },
    { value: "reset", label: "Reset" },
    { value: "increment", label: "Increment (counter/dial)" },
    { value: "goto", label: "Go to section (dial)" },
  ];

  function appendCallbackRow(cb) {
    const id =
      cb.id ||
      (crypto.randomUUID
        ? crypto.randomUUID()
        : `cb-${Date.now()}-${Math.random()}`);
    const initial = {
      id,
      when: cb.when || { type: "complete" },
      then: cb.then || { type: "sound" },
    };

    const row = document.createElement("div");
    row.className = "timers-callback-row";
    row.dataset.cbId = id;

    function paint(snapshot) {
      row.innerHTML = renderCallbackRow(snapshot);
      row
        .querySelector(".timers-callback-remove")
        .addEventListener("click", () => row.remove());
      // Each type-select repaints just the row, reading current state
      // first so both halves' other values survive.
      row.querySelectorAll("[data-cb-typeselect]").forEach((sel) => {
        sel.addEventListener("change", () => paint(readRow(row)));
      });
      // Wire dynamic side-effects: sound preview, chain-op repaint.
      const chimeSel = row.querySelector('[data-cb-then="chime"]');
      const preview = row.querySelector("[data-timers-sound-preview]");
      preview?.addEventListener("click", () => previewChime(chimeSel.value));
      row
        .querySelector('[data-cb-then="op"]')
        ?.addEventListener("change", () => paint(readRow(row)));
    }
    paint(initial);
    callbacksList.appendChild(row);
  }

  // Snapshot one row to a {id, when, then} hash. Shared between repaints
  // and the final readCallbacks() collection.
  function readRow(row) {
    const id = row.dataset.cbId;
    const whenType =
      row.querySelector('[data-cb-when="type"]')?.value || "complete";
    const thenType =
      row.querySelector('[data-cb-then="type"]')?.value || "sound";
    return { id, when: readWhen(row, whenType), then: readThen(row, thenType) };
  }

  function readWhen(row, type) {
    const w = { type };
    switch (type) {
      case "countdown_at":
        w.remaining_ms = parseCountdownAtToMs(
          row.querySelector('[data-cb-when="remaining_text"]')?.value,
        );
        break;
      case "counter_reaches":
        w.value = parseInt(
          row.querySelector('[data-cb-when="value"]')?.value,
          10,
        );
        if (Number.isNaN(w.value)) w.value = 0;
        w.direction =
          row.querySelector('[data-cb-when="direction"]')?.value || "any";
        break;
      case "dial_step": {
        const section = row
          .querySelector('[data-cb-when="section"]')
          ?.value?.trim();
        const sub = row.querySelector('[data-cb-when="sub"]')?.value?.trim();
        if (section) w.section = section;
        if (sub) w.sub = sub;
        break;
      }
    }
    return w;
  }

  function readThen(row, type) {
    const t = { type };
    switch (type) {
      case "push":
        t.title = row.querySelector('[data-cb-then="title"]')?.value || "";
        break;
      case "sound":
        t.chime = row.querySelector('[data-cb-then="chime"]')?.value || "soft";
        t.cadence =
          row.querySelector('[data-cb-then="cadence"]')?.value || "once";
        break;
      case "jil":
        t.trigger = row.querySelector('[data-cb-then="trigger"]')?.value || "";
        break;
      case "chain": {
        t.target_timer_id =
          parseInt(
            row.querySelector('[data-cb-then="target_timer_id"]')?.value,
            10,
          ) || null;
        t.op = row.querySelector('[data-cb-then="op"]')?.value || "start";
        const byEl = row.querySelector('[data-cb-then="by"]');
        if (byEl) t.by = parseInt(byEl.value, 10) || 1;
        const secEl = row.querySelector('[data-cb-then="section"]');
        if (secEl) t.section = secEl.value.trim();
        break;
      }
    }
    return t;
  }

  function renderCallbackRow(cb) {
    const whenArgs = renderWhenArgs(cb.when);
    const thenArgs = renderThenArgs(cb.then);
    const kind = field("kind").value;
    // Keep the currently-selected when type visible even if it doesn't
    // apply to the current kind — e.g. a callback authored as
    // countdown_at and then the timer's kind got switched to dial.
    // Better to show it (so the user can fix it) than to silently drop it.
    const whenOpts = WHEN_TYPES.filter(
      (o) => o.kinds.includes(kind) || cb.when.type === o.value,
    );
    return `
      <button type="button" class="timers-callback-remove" aria-label="Remove">&times;</button>
      <section class="cb-half cb-when">
        <header class="cb-label">When</header>
        <select data-cb-typeselect data-cb-when="type">
          ${whenOpts
            .map(
              (o) =>
                `<option value="${o.value}" ${cb.when.type === o.value ? "selected" : ""}>${o.label}</option>`,
            )
            .join("")}
        </select>
        ${whenArgs ? `<div class="cb-args">${whenArgs}</div>` : ""}
      </section>
      <section class="cb-half cb-then">
        <header class="cb-label">Then</header>
        <select data-cb-typeselect data-cb-then="type">
          ${THEN_TYPES.map(
            (o) =>
              `<option value="${o.value}" ${cb.then.type === o.value ? "selected" : ""}>${o.label}</option>`,
          ).join("")}
        </select>
        ${thenArgs ? `<div class="cb-args">${thenArgs}</div>` : ""}
      </section>
    `;
  }

  function renderWhenArgs(w) {
    switch (w.type) {
      case "countdown_at":
        return `
          <input type="text" data-cb-when="remaining_text"
                 placeholder="e.g. 1m23s or 0:30"
                 value="${esc(msToCountdownAtText(w.remaining_ms))}">
        `;
      case "counter_reaches":
        return `
          <input type="number" data-cb-when="value" placeholder="value" value="${esc(w.value ?? "")}">
          <select data-cb-when="direction">
            <option value="any"         ${w.direction === "any" || !w.direction ? "selected" : ""}>either direction</option>
            <option value="increasing"  ${w.direction === "increasing" ? "selected" : ""}>only when increasing</option>
            <option value="decreasing"  ${w.direction === "decreasing" ? "selected" : ""}>only when decreasing</option>
          </select>
        `;
      case "dial_step":
        return `
          <input type="text" data-cb-when="section"
                 placeholder="Section (blank = any)" value="${esc(w.section || "")}">
          <input type="text" data-cb-when="sub"
                 placeholder="Sub (optional)" value="${esc(w.sub || "")}">
        `;
    }
    return "";
  }

  function renderThenArgs(t) {
    switch (t.type) {
      case "push":
        return `
          <input type="text" data-cb-then="title"
                 placeholder="Title (defaults to timer name)" value="${esc(t.title || "")}">
        `;
      case "sound": {
        const chime = t.chime || "soft";
        const cadence = t.cadence || "once";
        return `
          <div class="timers-sound-chime">
            <select data-cb-then="chime">
              ${CHIME_NAMES.map(
                (c) =>
                  `<option value="${c}" ${c === chime ? "selected" : ""}>${capitalize(c)}</option>`,
              ).join("")}
            </select>
            <button type="button" class="timers-sound-preview" data-timers-sound-preview aria-label="Preview chime">▶</button>
          </div>
          <select data-cb-then="cadence">
            ${CADENCE_OPTIONS.map(
              (o) =>
                `<option value="${o.value}" ${o.value === cadence ? "selected" : ""}>${o.label}</option>`,
            ).join("")}
          </select>
        `;
      }
      case "jil":
        return `
          <input type="text" data-cb-then="trigger"
                 placeholder="jil-trigger-name" value="${esc(t.trigger || "")}">
        `;
      case "chain": {
        // Conditional fields: `by` for increment, `section` for goto.
        // Show both when relevant; only those fields are read back.
        const op = t.op || "start";
        const extra =
          op === "increment"
            ? `<input type="number" data-cb-then="by" placeholder="by" value="${esc(t.by ?? 1)}" style="width:5em">`
            : op === "goto"
              ? `<input type="text" data-cb-then="section" placeholder="Section name" value="${esc(t.section || "")}">`
              : "";
        return `
          <div class="timers-callback-chain">
            ${chainTimerSelect(t.target_timer_id)}
            <select data-cb-then="op">
              ${CHAIN_OPS.map(
                (o) =>
                  `<option value="${o.value}" ${o.value === op ? "selected" : ""}>${o.label}</option>`,
              ).join("")}
            </select>
            ${extra}
          </div>
        `;
      }
    }
    return "";
  }

  function chainTimerSelect(currentId) {
    const opts = Array.from(store.timers.values())
      .filter((t) => t.id !== editingId)
      .sort(
        (a, b) => (a.pos_y || 0) - (b.pos_y || 0) || (a.id || 0) - (b.id || 0),
      )
      .map((t) => {
        const label = (t.name || timerPlaceholderName(t)) + ` (${t.kind})`;
        const sel = currentId && Number(currentId) === t.id ? "selected" : "";
        return `<option value="${t.id}" ${sel}>${esc(label)}</option>`;
      })
      .join("");
    return `<select data-cb-then="target_timer_id"><option value="">— choose timer —</option>${opts}</select>`;
  }

  // The fallback identifier the dropdown falls back to when a timer
  // has no user-set name. Surfaced as the placeholder on the Name
  // input so the user can see what their timer is identified as.
  function timerPlaceholderName(t) {
    return `${capitalize(t.kind)} ${t.id}`;
  }

  // Round-trip ms ↔ human ("1m23s" / "0:30" / "45s") for countdown_at.
  // Reuses parseDuration which already handles all these formats.
  function parseCountdownAtToMs(s) {
    const seconds = parseDuration(String(s || "").trim());
    return Number.isFinite(seconds) && seconds > 0
      ? Math.round(seconds * 1000)
      : 0;
  }
  function msToCountdownAtText(ms) {
    if (!ms || ms <= 0) return "";
    return humanizeSeconds(Math.round(ms / 1000));
  }

  function capitalize(s) {
    return s.charAt(0).toUpperCase() + s.slice(1);
  }

  function readCallbacks() {
    return Array.from(
      callbacksList.querySelectorAll(".timers-callback-row"),
    ).map((row) => readRow(row));
  }

  // Adapter for callbacks saved under the OLD flat shape
  // ({ event, type, ...flat fields }). Mirrors Timer#normalize_callback
  // on the server so editing an unupgraded timer keeps working without
  // a forced dev-script run.
  function upgradeLegacyCallback(cb) {
    if (cb && cb.when && cb.then) return cb;
    if (!cb || !cb.type)
      return { when: { type: "complete" }, then: { type: "sound" } };

    const w =
      cb.event === "confirm"
        ? { type: "confirm" }
        : cb.event === "step"
          ? {
              type: "dial_step",
              section: cb.match_section || "",
              sub: cb.match_sub || "",
            }
          : { type: "complete" };

    let t;
    switch (cb.type) {
      case "push":
        t = { type: "push", title: cb.title || "" };
        break;
      case "sound":
        t = {
          type: "sound",
          chime: cb.chime || "soft",
          cadence: cb.cadence || "once",
        };
        break;
      case "jil":
        t = { type: "jil", trigger: cb.trigger || "" };
        break;
      case "chain":
        t = {
          type: "chain",
          target_timer_id: cb.target_timer_id || null,
          op: cb.op || "start",
        };
        if (cb.by != null) t.by = cb.by;
        if (cb.goto_section) t.section = cb.goto_section;
        break;
      default:
        t = { type: "sound" };
    }
    return { id: cb.id, when: w, then: t };
  }

  function esc(s) {
    return String(s).replace(
      /[&<>"']/g,
      (c) =>
        ({
          "&": "&amp;",
          "<": "&lt;",
          ">": "&gt;",
          '"': "&quot;",
          "'": "&#39;",
        })[c],
    );
  }

  dialog.querySelectorAll("[data-timers-cb-add]").forEach((b) => {
    b.addEventListener("click", () => {
      // Add-buttons preset the THEN type; user picks WHEN via the row's
      // dropdown. Defaults: "Timer completes" when, picked then.
      appendCallbackRow({
        when: { type: "complete" },
        then: { type: b.dataset.timersCbAdd },
      });
    });
  });

  field("kind").addEventListener("change", (e) => {
    setKindVisibility(e.target.value);
    // The When-options dropdown is filtered by kind, so we re-paint
    // every existing callback row whenever the user changes kind.
    // Each row's current state is snapshotted via readRow first so
    // values survive the rebuild.
    const snapshots = Array.from(
      callbacksList.querySelectorAll(".timers-callback-row"),
    ).map(readRow);
    callbacksList.innerHTML = "";
    snapshots.forEach((cb) => appendCallbackRow(cb));
  });
  durationInput?.addEventListener("input", updateDurationPreview);
  dialog.querySelectorAll("[data-timers-modal-close]").forEach((b) => {
    b.addEventListener("click", () => dialog.close());
  });

  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    const payload = readForm();
    if (mode === "quick") {
      const labelVal = labelInput?.value?.trim();
      const seconds =
        payload.kind === "countdown"
          ? Math.round(payload.duration_ms / 1000)
          : null;
      await onSaveQuick?.({
        label: labelVal || null,
        duration_seconds: seconds,
        color: payload.color,
        pinned: editingQuickIsPinned,
        template: payload,
      });
    } else if (editingId) {
      await actions.update(editingId, payload);
    } else {
      await actions.create(payload);
    }
    dialog.close();
  });

  deleteBtn.addEventListener("click", async () => {
    if (mode !== "timer" || !editingId) return;
    if (!confirm("Delete this timer?")) return;
    await actions.destroy(editingId);
    dialog.close();
  });

  // Save the current timer-edit form as a Saved Template (unpinned).
  templateBtn.addEventListener("click", async () => {
    if (mode !== "timer") return;
    const payload = readForm();
    const seconds =
      payload.kind === "countdown"
        ? Math.round(payload.duration_ms / 1000)
        : null;
    const labelDefault =
      payload.name ||
      (seconds ? defaultLabelForSeconds(seconds) : "Saved timer");
    const label = window.prompt("Save as template — label?", labelDefault);
    if (label === null) return;
    const sortMax = Array.from(store.quickButtons.values()).reduce(
      (m, q) => Math.max(m, q.sort_order || 0),
      -1,
    );
    await actions.createQuick({
      label: label.trim() || null,
      duration_seconds: seconds,
      color: payload.color,
      sort_order: sortMax + 1,
      pinned: false,
      template: payload,
    });
  });

  function open({ timer, quick } = {}) {
    if (quick) {
      mode = "quick";
      editingId = quick.id || null;
      editingQuickIsPinned = !!quick.pinned;
      onSaveQuick = quick.onSave;
      const tmpl =
        quick.template && Object.keys(quick.template).length > 0
          ? quick.template
          : {
              kind: "countdown",
              duration_ms: (quick.duration_seconds || 300) * 1000,
              callbacks: defaultCallbacks(),
            };
      titleEl.textContent = quick.id
        ? quick.pinned
          ? "Edit quick button"
          : "Edit saved timer"
        : quick.pinned === false
          ? "New saved timer"
          : "New quick button";
      deleteBtn.hidden = true;
      templateBtn.hidden = true;
      setModeVisibility();
      labelInput.value = quick.label || "";
      setFields(tmpl);
    } else {
      mode = "timer";
      editingId = timer?.id || null;
      onSaveQuick = null;
      titleEl.textContent = timer ? "Edit timer" : "New timer";
      deleteBtn.hidden = !timer;
      templateBtn.hidden = false;
      setModeVisibility();
      setFields(
        timer || {
          kind: "countdown",
          duration_ms: 5 * 60 * 1000,
          callbacks: defaultCallbacks(),
        },
      );
    }
    dialog.showModal();
  }

  return { open };
}

function defaultCallbacks() {
  // Sound is the default — gentle chime, fires once on completion.
  return [
    {
      id: "cb-init-sound",
      event: "complete",
      type: "sound",
      chime: "soft",
      cadence: "once",
    },
  ];
}
