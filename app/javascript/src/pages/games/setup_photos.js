// Photos in a game's setup notes. "Add photo", a pasted picture, or one
// dropped on the box all upload to the game and drop the markdown that shows
// it in at the cursor. Used by the settings page (wired below) and the setup
// screen of a live play.
import { api } from "./api";

export function pickAndInsertPhoto(templateId, textarea, button) {
  const input = document.createElement("input");
  input.type = "file";
  input.accept = "image/*";
  input.addEventListener("change", () => {
    if (input.files?.[0]) uploadAndInsert(templateId, textarea, input.files[0], button);
  });
  input.click();
}

export function wirePhotoPasteAndDrop(templateId, textarea, button) {
  const images = (files) => [...(files || [])].filter((f) => f.type.startsWith("image/"));
  textarea.addEventListener("paste", (e) => {
    const found = images(e.clipboardData?.files);
    if (!found.length) return;
    e.preventDefault();
    found.reduce((chain, file) => chain.then(() => uploadAndInsert(templateId, textarea, file, button)), Promise.resolve());
  });
  textarea.addEventListener("dragover", (e) => { if (e.dataTransfer?.types?.includes("Files")) e.preventDefault(); });
  textarea.addEventListener("drop", (e) => {
    const found = images(e.dataTransfer?.files);
    if (!found.length) return;
    e.preventDefault();
    found.reduce((chain, file) => chain.then(() => uploadAndInsert(templateId, textarea, file, button)), Promise.resolve());
  });
}

async function uploadAndInsert(templateId, textarea, file, button) {
  const label = button?.textContent;
  if (button) { button.disabled = true; button.textContent = "Uploading…"; }
  try {
    const form = new FormData();
    form.append("file", file);
    const res = await fetch(`/games/templates/${templateId}/setup_images`, {
      method: "POST", credentials: "same-origin", body: form,
      headers: { "Accept": "application/json", "X-CSRF-Token": api.csrfToken() },
    });
    if (!res.ok) throw new Error(`upload -> ${res.status}`);
    insertAtCursor(textarea, (await res.json()).markdown);
  } catch (e) {
    window.alert("Couldn't upload that photo - check the connection and try again.");
  } finally {
    if (button) { button.disabled = false; button.textContent = label; }
  }
}

// On a line of its own, so it renders as a picture rather than mid-sentence.
function insertAtCursor(textarea, text) {
  const at = textarea.selectionStart ?? textarea.value.length;
  const before = textarea.value.slice(0, at);
  const after = textarea.value.slice(at);
  const lead = before && !before.endsWith("\n") ? "\n" : "";
  const trail = after.startsWith("\n") ? "" : "\n";
  textarea.value = `${before}${lead}${text}${trail}${after}`;
  const cursor = (before + lead + text + trail).length;
  textarea.setSelectionRange(cursor, cursor);
  textarea.focus();
}

function boot() {
  document.querySelectorAll("[data-games-setup-photo]").forEach((button) => {
    const textarea = button.closest("details, form")?.querySelector("[data-games-setup-notes]");
    if (!textarea) return;
    button.addEventListener("click", () => pickAndInsertPhoto(button.dataset.templateId, textarea, button));
    wirePhotoPasteAndDrop(button.dataset.templateId, textarea, button);
  });
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", boot);
} else {
  boot();
}
