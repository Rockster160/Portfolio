// A phone-sized number pad, so typing a value never summons the system
// keyboard (which shoves the sheet around and hides half the screen).
// Returns the HTML; `wireKeypad` keeps the display in sync and calls
// onSubmit(number) from the go key.
export function keypadHtml({ goLabel = "Record", allowNegative = false, placeholder = "Type a number" } = {}) {
  const left = allowNegative ? '<button type="button" data-key="neg">±</button>' : '<button type="button" data-key="clear">C</button>';
  return `
    <div class="games-keypad-display is-empty games-num" data-display data-placeholder="${placeholder}">${placeholder}</div>
    <div class="games-keypad">
      ${[1, 2, 3, 4, 5, 6, 7, 8, 9].map((n) => `<button type="button" data-key="${n}">${n}</button>`).join("")}
      ${left}
      <button type="button" data-key="0">0</button>
      <button type="button" data-key="back" aria-label="Delete">⌫</button>
    </div>
    <button type="button" class="games-btn games-btn-primary games-btn-block games-btn-lg" data-key="go" style="margin-top:10px" disabled>${goLabel}</button>
  `;
}

export function wireKeypad(root, onSubmit) {
  let text = "";
  const display = root.querySelector("[data-display]");
  const go = root.querySelector('[data-key="go"]');

  function show() {
    const empty = text === "" || text === "-";
    display.classList.toggle("is-empty", empty);
    display.textContent = empty ? display.dataset.placeholder : text;
    go.disabled = empty;
  }

  root.querySelectorAll("[data-key]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const key = btn.dataset.key;
      if (key === "go") {
        const n = parseInt(text, 10);
        if (!Number.isNaN(n)) onSubmit(n);
        return;
      }
      if (key === "back") text = text.slice(0, -1);
      else if (key === "clear") text = "";
      else if (key === "neg") text = text.startsWith("-") ? text.slice(1) : `-${text}`;
      else if (text.replace("-", "").length < 5) text = (text === "0" ? "" : text) + key;
      show();
    });
  });
  show();
}
