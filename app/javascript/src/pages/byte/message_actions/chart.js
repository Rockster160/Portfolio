// A chart Buddy drew in the thread (Buddy::Charts). Drawn from the numbers it
// came to when it was posted, with a button that keeps it on the Charts page
// as it stands - the message carries the chart's own description, not just
// the picture, so the saved one can be opened and changed like any other.
import { chartConfig, loadChartJs, markerColor } from "../../../support/chart_config.js";

// container -> its Chart instance, since a repaint draws it again.
const DRAWN = new WeakMap();

function escapeHtml(text) {
  return String(text ?? "").replace(/[&<>"']/g, (c) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  })[c]);
}

function legendRows(payload) {
  const rows = [];
  const sets = payload.datasets || [];
  if (sets.length > 1) {
    sets.forEach((set) => {
      rows.push(`<span class="byte-chart-key"><i style="background:${escapeHtml(set.color)}"></i>${escapeHtml(set.label)}</span>`);
    });
  }
  const marks = {};
  (payload.markers || []).forEach((mark) => { marks[mark.name] = markerColor(mark); });
  Object.keys(marks).forEach((name) => {
    rows.push(`<span class="byte-chart-key byte-chart-key-marker"><i style="border-color:${escapeHtml(marks[name])}"></i>${escapeHtml(name)}</span>`);
  });
  return rows.join("");
}

function savedLink(id) {
  return `<a class="byte-chart-open" href="/custom_charts/${encodeURIComponent(id)}">Saved · Open in Charts</a>`;
}

async function save(message, footer, button) {
  button.disabled = true;
  button.textContent = "Saving…";
  try {
    const csrf = document.querySelector('meta[name="csrf-token"]')?.getAttribute("content") || "";
    const res = await fetch("/custom_charts/save_message", {
      method:      "POST",
      credentials: "same-origin",
      headers:     { "Content-Type": "application/json", Accept: "application/json", "X-CSRF-Token": csrf },
      body:        JSON.stringify({ message_id: message.id }),
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const json = await res.json();
    message.metadata.chart.saved_id = json.id;
    footer.innerHTML = savedLink(json.id);
  } catch (_err) {
    button.disabled = false;
    button.textContent = "Couldn't save - try again";
  }
}

export function renderChart(container, message) {
  const drawn = message?.metadata?.chart;
  const payload = drawn?.payload;
  if (!payload) return false;

  DRAWN.get(container)?.destroy();
  DRAWN.delete(container);

  container.className = "byte-chart";
  container.innerHTML = `
    ${payload.range_label ? `<div class="byte-chart-range">${escapeHtml(payload.range_label)}</div>` : ""}
    <div class="byte-chart-canvas"><canvas></canvas></div>
    <div class="byte-chart-legend">${legendRows(payload)}</div>
    <div class="byte-chart-footer"></div>
  `;

  const footer = container.querySelector(".byte-chart-footer");
  if (drawn.saved_id) {
    footer.innerHTML = savedLink(drawn.saved_id);
  } else {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "byte-chart-save";
    button.textContent = "Save to Charts";
    button.addEventListener("click", () => save(message, footer, button));
    footer.appendChild(button);
  }

  if (payload.error) {
    container.querySelector(".byte-chart-canvas").innerHTML = `<div class="byte-chart-empty">${escapeHtml(payload.error)}</div>`;
    return true;
  }

  const canvas = container.querySelector("canvas");
  loadChartJs().then(() => {
    if (!canvas.isConnected) return;
    DRAWN.set(container, new Chart(canvas, chartConfig(payload)));
  }).catch(() => {
    container.querySelector(".byte-chart-canvas").innerHTML = '<div class="byte-chart-empty">The chart couldn\'t load.</div>';
  });
  return true;
}
