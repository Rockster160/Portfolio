// Counts the QR/code page down to its own expiry so the screen never shows a
// credential the server has already stopped accepting.
$(document).ready(function() {
  const root = document.querySelector("[data-device-login]");
  if (!root) return;

  const readout = root.querySelector("[data-device-login-countdown]");
  let remaining = parseInt(root.dataset.secondsRemaining, 10);
  if (isNaN(remaining)) return;

  function render() {
    if (remaining <= 0) {
      root.classList.add("expired");
      readout.textContent = "";
      return;
    }

    const minutes = Math.floor(remaining / 60);
    const seconds = String(remaining % 60).padStart(2, "0");
    readout.textContent = "Expires in " + minutes + ":" + seconds;
  }

  render();
  const tick = setInterval(function() {
    remaining -= 1;
    render();
    if (remaining <= 0) clearInterval(tick);
  }, 1000);
});
