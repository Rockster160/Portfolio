// A production script's card (ProductionScripts::Card): its title and where to
// go for it, the code itself in a box twenty lines tall that scrolls both ways
// rather than wrapping, and Approve / Skip under it.
//
// A card with nothing left to decide folds down to its header: one a newer
// version replaced points down to it, and one whose script has run or been
// skipped keeps its code behind a disclosure.
//
// Everything on it comes from `message.script`, which the server reads from the
// script each time the message is sent - so a press here does nothing to the
// card itself. The server repaints every card for the script once it changes.
import { escapeAttr, escapeHtml } from "./markdown";

async function post(scriptId, verb) {
  const csrfMeta = document.querySelector('meta[name="csrf-token"]');
  const res = await fetch(
    `/byte/production_scripts/${encodeURIComponent(scriptId)}/${verb}`,
    {
      method:      "POST",
      credentials: "same-origin",
      headers:     {
        "Content-Type": "application/json",
        "Accept":       "application/json",
        "X-CSRF-Token": csrfMeta ? csrfMeta.getAttribute("content") : "",
      },
      body: "{}",
    },
  );
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return res.json().catch(() => ({}));
}

function link(url, label) {
  if (!url) return "";
  return `<a href="${escapeAttr(url)}" target="_blank" rel="noopener">${escapeHtml(label)}</a>`;
}

function approveQuestion(script) {
  if (script.deployed) return "Run this in production now?";
  return `Run this in production once ${script.commit} is deployed?`;
}

export function renderProductionScriptCard(bodyEl, message) {
  const script = message.script;
  if (!script) {
    // The script is gone: the message's own words still say what it was.
    bodyEl.textContent = message.body || "";
    return;
  }

  const links = [
    link(script.url, "Full page"),
    script.pr_url ? link(script.pr_url, `PR #${script.pr_number}`) : "",
    link(script.session_url, "Open it in Claude"),
  ].filter(Boolean).join(" · ");

  const head = `
    <div class="byte-script-head">
      <div class="byte-script-title">${escapeHtml(script.title)}</div>
      <div class="byte-script-meta">
        ${script.superseded ? "" : `<span class="byte-script-status byte-script-status-${escapeAttr(script.status)}">${escapeHtml(script.label)}</span>`}
        ${script.step && script.approvable && !script.superseded ? `<span>${escapeHtml(script.step)}</span>` : ""}
      </div>
      <div class="byte-script-links">${links}</div>
    </div>
  `;

  if (script.superseded) {
    bodyEl.innerHTML = `${head}<div class="byte-script-superseded">A newer version is further down.</div>`;
    return;
  }

  if (script.settled) {
    bodyEl.innerHTML = `
      ${head}
      <details class="byte-script-folded">
        <summary>The script</summary>
        <div class="byte-script-code ps-code">${script.html || ""}</div>
      </details>
    `;
    return;
  }

  const buttons = [
    script.approvable
      ? `<button type="button" class="byte-action-btn byte-action-btn-colored byte-script-approve" data-script-verb="approve">
           <span class="byte-action-btn-label">Approve</span>
         </button>`
      : "",
    script.skippable
      ? `<button type="button" class="byte-action-btn byte-script-skip" data-script-verb="skip">
           <span class="byte-action-btn-label">Skip</span>
         </button>`
      : "",
  ].join("");

  bodyEl.innerHTML = `
    ${head}
    <div class="byte-script-code ps-code">${script.html || ""}</div>
    ${buttons ? `<div class="byte-action-buttons byte-script-actions">${buttons}</div>` : ""}
    <div class="byte-script-error" hidden></div>
  `;

  const errorEl = bodyEl.querySelector(".byte-script-error");
  const els = Array.from(bodyEl.querySelectorAll("[data-script-verb]"));
  els.forEach((el) => {
    el.addEventListener("click", async () => {
      const verb = el.dataset.scriptVerb;
      if (verb === "approve" && !window.confirm(approveQuestion(script))) return;

      els.forEach((other) => {
        other.disabled = true;
        other.classList.add("disabled");
      });
      try {
        await post(script.id, verb);
      } catch (e) {
        console.warn("[byte] production script press failed", e);
        errorEl.textContent = verb === "approve" ? "Couldn't approve it. Try again." : "Couldn't skip it. Try again.";
        errorEl.hidden = false;
        els.forEach((other) => {
          other.disabled = false;
          other.classList.remove("disabled");
        });
      }
    });
  });
}
