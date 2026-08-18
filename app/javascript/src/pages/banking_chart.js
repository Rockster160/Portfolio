// The over-time chart on /system/banking, and the date pickers that scope it.
//
// Everything here reloads the page rather than fetching. The chart is a view of
// whatever the search matched, so a new bucket or a new date range is a new
// search — and the table, the totals and the category bars all have to move
// with it. Re-rendering the canvas alone would leave four numbers on screen
// describing a different set of rows than the chart above them.
$(document).ready(function() {
  if ($(".ctr-system.act-banking").length == 0) { return }

  const form = document.getElementById("bank-search-form")
  const queryInput = form ? form.querySelector('input[name="q"]') : null

  // --- Dates live in the query ---------------------------------------------

  // Matches what the server strips and re-reads (SystemController::TIMESTAMP_TERM).
  // Longest operators first, or `>=` matches as `>` and orphans the `=`.
  const TIMESTAMP_TERM = /(^|\s)timestamp(>=|<=|>|<|::|:)\S+/gi

  function withoutDates(query) {
    return query.replace(TIMESTAMP_TERM, " ").replace(/\s+/g, " ").trim()
  }

  // `>=` and `<=` on purpose: both are inclusive of the day named, so the
  // range in the box is exactly the range in the pickers. `>` and `<` skip the
  // whole unit, which is the documented trap and no way to build a range.
  function applyDates(from, to) {
    if (!form || !queryInput) { return }

    const terms = []
    if (from) { terms.push("timestamp>=" + from) }
    if (to) { terms.push("timestamp<=" + to) }

    queryInput.value = [withoutDates(queryInput.value)].concat(terms).join(" ").trim()
    form.submit()
  }

  const fromInput = document.querySelector("[data-date-from]")
  const toInput = document.querySelector("[data-date-to]")

  function currentDates() {
    return [fromInput ? fromInput.value : "", toInput ? toInput.value : ""]
  }

  ;[fromInput, toInput].forEach(function(el) {
    if (!el) { return }
    el.addEventListener("change", function() {
      const dates = currentDates()
      applyDates(dates[0], dates[1])
    })
  })

  const clearBtn = document.querySelector("[data-date-clear]")
  if (clearBtn) {
    clearBtn.addEventListener("click", function() { applyDates("", "") })
  }

  // The bucket belongs to the search form by `form=`, so changing it only needs
  // to submit — the value rides along as a param of its own.
  const bucketSelect = document.querySelector("[data-bucket-select]")
  if (bucketSelect && form) {
    bucketSelect.addEventListener("change", function() { form.submit() })
  }

  // --- The chart ------------------------------------------------------------

  if (typeof Chart === "undefined") { return }

  const canvas = document.querySelector("[data-bank-canvas]")
  const payloadEl = document.querySelector("[data-bank-chart-payload]")
  if (!canvas || !payloadEl) { return }

  let payload
  try { payload = JSON.parse(payloadEl.textContent) } catch (e) { return }

  const unit = payload.unit || ""

  function fmtMoney(value) {
    if (value === null || value === undefined) { return "—" }
    return unit + Number(value).toLocaleString(undefined, {
      minimumFractionDigits: 2, maximumFractionDigits: 2,
    })
  }

  function escapeHtml(str) {
    return String(str == null ? "" : str).replace(/[&<>"']/g, function(c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]
    })
  }

  function datasetTotal(ds) {
    return (ds.data || []).reduce(function(sum, v) {
      return sum + (typeof v === "number" ? v : 0)
    }, 0)
  }

  function renderLegend() {
    const el = document.querySelector("[data-bank-chart-legend]")
    if (!el) { return }

    // Presentational order only — biggest first. The dataset order, and so the
    // stacking, is untouched.
    const rows = (payload.datasets || []).slice().sort(function(a, b) {
      return datasetTotal(b) - datasetTotal(a)
    })
    el.innerHTML = rows.map(function(ds) {
      return '<div class="cc-legend-row"><span class="cc-swatch" style="background-color:' +
        escapeHtml(ds.color) + '"></span><span class="cc-legend-label">' +
        escapeHtml(ds.label) + '</span><span class="cc-legend-total">' +
        escapeHtml(fmtMoney(datasetTotal(ds))) + "</span></div>"
    }).join("")
  }

  function setEmpty(message) {
    const el = document.querySelector("[data-bank-chart-empty]")
    if (!el) { return }
    el.textContent = message || ""
    el.style.display = message ? "flex" : "none"
  }

  function build() {
    const datasets = (payload.datasets || []).map(function(ds) {
      return {
        label: ds.label,
        data: ds.data,
        backgroundColor: ds.color,
        borderColor: ds.color,
        borderWidth: 0,
        // Square: a rounded end on a thin stacked segment reads as detached.
        borderRadius: 0,
        borderSkipped: false,
        categoryPercentage: 0.7,
        barPercentage: 0.9,
        maxBarThickness: 48,
        minBarLength: 2,
        // Out and in are distinct groups, so Chart.js draws them side by side
        // within the bucket and stacks each one internally.
        stack: ds.stack || "out",
      }
    })

    return {
      type: "bar",
      data: { labels: payload.labels || [], datasets: datasets },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        interaction: { mode: "index", intersect: false },
        scales: {
          y: {
            stacked: true,
            beginAtZero: true,
            ticks: { color: "#C9D1D9", callback: function(v) { return unit + v } },
            grid: { color: "rgba(255,255,255,0.05)" },
          },
          x: {
            stacked: true,
            ticks: { color: "#C9D1D9", maxRotation: 0, autoSkip: true },
            grid: { color: "rgba(255,255,255,0.05)" },
          },
        },
        plugins: {
          legend: { display: false },
          tooltip: {
            itemSort: function(a, b) { return b.parsed.y - a.parsed.y },
            // A category worth zero in this bucket draws nothing, so listing it
            // describes something that isn't there — and with 22 categories it
            // is eighteen lines of "$0.00" pushing the four real ones off.
            filter: function(ctx) { return !!ctx.parsed.y },
            callbacks: {
              label: function(ctx) { return ctx.dataset.label + ": " + fmtMoney(ctx.parsed.y) },
            },
          },
        },
      },
    }
  }

  renderLegend()
  setEmpty(payload.message || null)
  if ((payload.datasets || []).length) { new Chart(canvas, build()) }
})
