// A ChartBuilder payload as a Chart.js config. Shared by the Charts page and a
// chart Buddy draws in the thread, so the two draw the same chart the same way.

const MARKER_COLOR = "rgba(250, 178, 25, 0.85)"

export function fmtValue(v, unit) {
  if (v === null || v === undefined) { return "—" }
  const n = Number(v)
  if (unit === "$") {
    return "$" + n.toLocaleString(undefined, { minimumFractionDigits: 0, maximumFractionDigits: 2 })
  }
  return n.toLocaleString()
}

export function markerColor(marker) {
  return (marker && marker.color) || MARKER_COLOR
}

// Chart.js and its date adapter, loaded the first time a chart is drawn on a
// page that didn't already include them (see custom_charts/_chart_assets).
const SCRIPTS = [
  "https://cdn.jsdelivr.net/npm/chart.js@4.3.0/dist/chart.umd.min.js",
  "https://cdn.jsdelivr.net/npm/chartjs-adapter-date-fns@3.0.0/dist/chartjs-adapter-date-fns.bundle.min.js",
]
let loading = null

export function loadChartJs() {
  if (typeof Chart !== "undefined") { return Promise.resolve() }
  if (loading) { return loading }

  const add = (src) => new Promise((resolve, reject) => {
    const el = document.createElement("script")
    el.src = src
    el.onload = resolve
    el.onerror = reject
    document.head.appendChild(el)
  })
  // In order: the adapter registers itself onto Chart.
  loading = add(SCRIPTS[0]).then(() => add(SCRIPTS[1])).catch((err) => {
    loading = null
    throw err
  })
  return loading
}

export function chartConfig(payload) {
  // Raw per-event data (bucket: none) has no categories to anchor bars to, so
  // hundreds of events render as hairline slivers. Always draw it as a line.
  const asLine = payload.chart_type === "line" || payload.time_axis
  const stacked = payload.chart_type === "stacked_bar" && !asLine
  const type = asLine ? "line" : "bar"
  const unit = payload.unit || ""

  const datasets = (payload.datasets || []).map(function(ds) {
    const base = { label: ds.label, data: ds.data, backgroundColor: ds.color, borderColor: ds.color }
    if (asLine) {
      base.borderWidth = 2
      // Drop the dots on dense series so the line itself stays readable.
      base.pointRadius = (ds.data && ds.data.length > 80) ? 0 : 3
      base.tension = 0.15
      base.fill = false
      base.spanGaps = false
    } else {
      base.borderWidth = 0
      // Rounded ends look detached on thin stacked segments; keep square there.
      base.borderRadius = stacked ? 0 : 4
      base.borderSkipped = false
      base.categoryPercentage = 0.7
      base.barPercentage = 0.9
      base.maxBarThickness = 48
      base.minBarLength = 2
      // Distinct stack groups (e.g. intake vs burn) render side by side per bucket.
      if (stacked) { base.stack = ds.stack || "stack" }
    }
    return base
  })

  const scales = {
    y: {
      stacked: stacked,
      beginAtZero: true,
      ticks: { color: "#C9D1D9", callback: function(v) { return unit === "$" ? "$" + v : v } },
      grid: { color: "rgba(255,255,255,0.05)" },
    },
    x: {
      stacked: stacked,
      ticks: { color: "#C9D1D9", maxRotation: 0, autoSkip: true },
      grid: { color: "rgba(255,255,255,0.05)" },
    },
  }
  if (payload.time_axis) {
    scales.x.type = "time"
    scales.x.time = { tooltipFormat: "PP" }
    // Pin the axis to the selected range so data and markers span the full
    // window, not just where events happen to fall (else edge markers clip).
    if (payload.window) {
      scales.x.min = payload.window.start
      scales.x.max = payload.window.end
    }
  }

  return {
    type: type,
    data: { labels: payload.labels || undefined, datasets: datasets },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      interaction: { mode: "index", intersect: false },
      scales: scales,
      plugins: {
        legend: { display: false },
        tooltip: {
          // Biggest first, matching the legend. A 22-series chart's readout
          // runs off the canvas, so whatever gets cut has to be the part
          // that matters least — in dataset order that was arbitrary.
          // Magnitude, so a burn series sorts by how much it moved rather
          // than by sitting below zero.
          itemSort: function(a, b) { return Math.abs(b.parsed.y) - Math.abs(a.parsed.y) },
          // A stacked segment worth zero draws nothing in the bar being
          // hovered, so listing it describes something that isn't there —
          // and in a month that used four categories, it is eighteen lines
          // of "$0.00" pushing the four real ones off the bottom. Stacked
          // only: on a line or plain bar a zero is a measurement that was
          // taken, and belongs in the readout.
          filter: stacked ? function(ctx) { return !!ctx.parsed.y } : undefined,
          callbacks: {
            label: function(ctx) { return ctx.dataset.label + ": " + fmtValue(ctx.parsed.y, unit) },
          },
        },
      },
    },
    plugins: [markerPlugin(payload)],
  }
}

// Draws a dashed vertical reference line for each marker-query event, in its
// event's color.
function markerPlugin(payload) {
  return {
    id: "ccMarkers",
    afterDatasetsDraw: function(c) {
      const marks = payload.markers || []
      if (!marks.length) { return }
      const area = c.chartArea
      const ctx = c.ctx
      ctx.save()
      ctx.lineWidth = 1.5
      ctx.setLineDash([5, 4])
      marks.forEach(function(m) {
        const px = markerPx(c, payload, m.ts)
        if (px === null || px < area.left || px > area.right) { return }
        ctx.strokeStyle = markerColor(m)
        ctx.beginPath()
        ctx.moveTo(px, area.top)
        ctx.lineTo(px, area.bottom)
        ctx.stroke()
      })
      ctx.restore()
    },
  }
}

// The x-pixel for a marker: direct on a time axis, mapped into its bucket on a
// category axis. Returns null when it can't be placed.
export function markerPx(c, payload, ms) {
  const xScale = c.scales.x
  if (payload.time_axis) {
    const px = xScale.getPixelForValue(ms)
    return (px === undefined) ? null : px
  }
  const idx = bucketIndexFor(ms, payload.buckets_ms)
  if (idx === null) { return null }
  // getPixelForValue(index) is math-based (offset-aware, immune to autoSkipped
  // ticks) and matches where the bars/points sit. getPixelForTick misses when
  // Chart.js skips ticks on dense axes.
  const px = xScale.getPixelForValue(idx)
  return (px === undefined || px === null || !isFinite(px)) ? null : px
}

// Index of the bucket a marker falls into (last start <= ms); null if before the first.
function bucketIndexFor(ms, buckets) {
  if (!buckets || !buckets.length) { return null }
  let idx = null
  for (let i = 0; i < buckets.length; i++) {
    if (buckets[i] <= ms) { idx = i } else { break }
  }
  return idx
}
