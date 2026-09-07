// Bulk counter adjust. Opened by holding a counter card's + or − button:
// type an amount instead of tapping eighteen times. Several numbers at
// once are summed, and a negative among them goes the other way — so a
// round of scoring reads `5 8 -2` and lands as one adjustment.
//
// The amount is sent as a RAW delta (`amount`, not `by`), so the
// counter's `step` never multiplies what was typed.

const MINUS = "−"; // U+2212, the real minus sign — reads as an operator

// Every integer in the text, however it was separated: spaces, commas,
// new lines, or nothing at all ("5-2" is 5 and −2). Decimals are not a
// thing here; the value column is an integer.
export function parseAmounts(text) {
  return (String(text || "").match(/[+-]?\d+/g) || [])
    .map((n) => parseInt(n, 10))
    .filter((n) => Number.isFinite(n));
}

export function setupCounterBulkModal({ root, store, actions }) {
  const dialog = root.querySelector("[data-timers-bulk-modal]");
  if (!dialog) return { open: () => {} };

  const form    = dialog.querySelector("[data-timers-bulk-form]");
  const title   = dialog.querySelector("[data-timers-bulk-title]");
  const sumEl   = dialog.querySelector("[data-timers-bulk-sum]");
  const termsEl = dialog.querySelector("[data-timers-bulk-terms]");
  const input   = dialog.querySelector("[data-timers-bulk-input]");
  const applyBtn = dialog.querySelector("[data-timers-bulk-apply]");

  // `sign` is which button was held: +1 adds what you type, −1 subtracts
  // it. Signs written into the field are relative to that.
  let timerId = null;
  let sign = 1;

  dialog.querySelectorAll("[data-timers-modal-close]").forEach((b) => {
    b.addEventListener("click", () => dialog.close());
  });

  function currentValue() {
    return store.timers.get(timerId)?.value ?? 0;
  }

  function signedAmounts() {
    return parseAmounts(input.value).map((n) => n * sign);
  }

  // `43 + 18 = 61` — where it is now, what this adds up to, where it
  // lands. The terms line under it only appears when there's more than
  // one, since a single term is already the whole sum.
  function repaint() {
    const amounts = signedAmounts();
    const total = amounts.reduce((a, b) => a + b, 0);
    const from = currentValue();

    if (amounts.length === 0) {
      sumEl.textContent = String(from);
      sumEl.classList.add("is-idle");
      termsEl.textContent = "";
      applyBtn.disabled = true;
      return;
    }

    sumEl.classList.remove("is-idle");
    sumEl.textContent = `${from} ${total < 0 ? MINUS : "+"} ${Math.abs(total)} = ${from + total}`;
    termsEl.textContent = amounts.length > 1 ? amounts.map(termText).join(" ") : "";
    applyBtn.disabled = total === 0;
  }

  function termText(n, i) {
    if (i === 0) return n < 0 ? `${MINUS}${Math.abs(n)}` : String(n);
    return `${n < 0 ? MINUS : "+"} ${Math.abs(n)}`;
  }

  input.addEventListener("input", repaint);

  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    const total = signedAmounts().reduce((a, b) => a + b, 0);
    dialog.close();
    if (total === 0 || timerId == null) return;

    await actions.increment(timerId, null, total);
  });

  return {
    open(id, direction) {
      const timer = store.timers.get(id);
      if (!timer || timer.kind !== "counter") return;

      timerId = id;
      sign = direction < 0 ? -1 : 1;
      input.value = "";
      const label = timer.name || "counter";
      title.textContent = sign < 0 ? `Subtract from ${label}` : `Add to ${label}`;
      repaint();
      dialog.showModal();
      requestAnimationFrame(() => input.focus());
    },
  };
}
