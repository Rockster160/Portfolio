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

  function submitDates() {
    const dates = currentDates()
    applyDates(dates[0], dates[1])
  }

  ;[fromInput, toInput].forEach(function(el) {
    if (!el) { return }
    el.addEventListener("change", submitDates)
    // The pickers sit INSIDE the search form, so Enter would submit it with
    // the old query still in the box and the date silently dropped. Take the
    // key and run the same path a change does.
    el.addEventListener("keydown", function(event) {
      if (event.key !== "Enter") { return }
      event.preventDefault()
      submitDates()
    })
  })

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

  function setEmpty(message) {
    const el = document.querySelector("[data-bank-chart-empty]")
    if (!el) { return }
    el.textContent = message || ""
    el.style.display = message ? "flex" : "none"
  }

  // --- The tooltip ----------------------------------------------------------

  let tooltipEl = null

  function tooltipNode() {
    if (!tooltipEl) {
      tooltipEl = document.createElement("div")
      tooltipEl.className = "bank-tooltip"
      document.body.appendChild(tooltipEl)
    }
    return tooltipEl
  }

  function node(tag, className, text) {
    const el = document.createElement(tag)
    if (className) { el.className = className }
    if (text !== undefined) { el.textContent = text }
    return el
  }

  // Money in and money out side by side, each headed by its total, so the
  // month reads as two sums before it reads as a list. A category worth zero
  // in this bucket draws nothing, so it isn't listed either.
  function tooltipColumn(title, rows) {
    const column = node("div", "bank-tooltip-col")
    const total = rows.reduce(function(sum, row) { return sum + row.value }, 0)
    const head = node("div", "bank-tooltip-head")
    head.appendChild(node("span", null, title))
    head.appendChild(node("span", null, fmtMoney(total)))
    column.appendChild(head)

    rows.sort(function(a, b) { return b.value - a.value }).forEach(function(row) {
      const line = node("div", "bank-tooltip-row")
      const swatch = node("span", "bank-tooltip-swatch")
      swatch.style.background = row.color
      line.appendChild(swatch)
      line.appendChild(node("span", "bank-tooltip-label", row.label))
      line.appendChild(node("span", "bank-tooltip-value", fmtMoney(row.value)))
      column.appendChild(line)
    })
    return column
  }

  function renderTooltip(context) {
    const tooltip = context.tooltip
    const el = tooltipNode()
    if (tooltip.opacity === 0 || !(tooltip.dataPoints || []).length) {
      el.style.opacity = 0
      return
    }

    const chart = context.chart
    const index = tooltip.dataPoints[0].dataIndex
    const columns = { in: [], out: [] }
    let balance = null
    chart.data.datasets.forEach(function(ds) {
      const value = Number(ds.data[index])
      if (ds.stack === "balance") { balance = ds.data[index]; return }
      if (!columns[ds.stack] || !value) { return }
      columns[ds.stack].push({ label: ds.label, color: ds.backgroundColor, value: value })
    })

    el.replaceChildren()
    el.appendChild(node("div", "bank-tooltip-title", chart.data.labels[index]))
    if (balance !== null && balance !== undefined) {
      el.appendChild(node("div", "bank-tooltip-balance", "Balance at start: " + fmtMoney(balance)))
    }
    const grid = node("div", "bank-tooltip-grid")
    grid.appendChild(tooltipColumn("In", columns.in))
    grid.appendChild(tooltipColumn("Out", columns.out))
    el.appendChild(grid)

    // Beside the hovered column, flipping to its left when the right side
    // would run off the screen, and top-aligned with the chart so a long list
    // hangs down past it rather than being cut off.
    const rect = chart.canvas.getBoundingClientRect()
    const gap = 12
    const width = el.offsetWidth
    const caret = rect.left + tooltip.caretX
    let left = caret + gap
    if (left + width > window.innerWidth - 8) { left = caret - gap - width }
    left = Math.max(8, Math.min(left, window.innerWidth - width - 8))

    el.style.left = (left + window.scrollX) + "px"
    el.style.top = (rect.top + window.scrollY + chart.chartArea.top) + "px"
    el.style.opacity = 1
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
        // No `minBarLength`: on a stacked axis Chart.js counts the padded
        // pixels into the stack, so every zero or cents-sized category lifts
        // the column by the dollars 2px is worth and the top stops matching
        // the axis. A tiny category is still in the tooltip.
        // Out and in are distinct groups, so Chart.js draws them side by side
        // within the bucket and stacks each one internally.
        stack: ds.stack || "out",
      }
    })

    // The dashboard figure as each bucket opened, on the same axis as the bars
    // so a month's spending reads directly against what there was to spend.
    const balance = payload.balance || []
    if (balance.some(function(v) { return v !== null && v !== undefined })) {
      datasets.push({
        type: "line",
        label: "Balance at start",
        data: balance,
        // Its own stack, or it would be summed onto the bars beneath it.
        stack: "balance",
        borderColor: "#E6EDF3",
        backgroundColor: "#E6EDF3",
        borderWidth: 2,
        pointRadius: 2,
        pointHoverRadius: 4,
        tension: 0.2,
        spanGaps: false,
        // Drawn over the bars rather than behind them.
        order: -1,
      })
    }

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
          // Drawn as HTML on the page, not on the canvas: a canvas tooltip
          // can't grow past the chart, and a month with fifteen categories
          // is taller than the chart is.
          tooltip: { enabled: false, external: renderTooltip },
        },
      },
    }
  }

  // The legend is rendered by the server, not from this payload: it is a
  // category PICKER and has to list every category the rest of the search
  // allows, including the ones this chart is not showing.
  setEmpty(payload.message || null)
  if ((payload.datasets || []).length) { new Chart(canvas, build()) }
})
