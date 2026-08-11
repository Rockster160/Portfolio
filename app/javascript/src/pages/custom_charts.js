$(document).ready(function() {
  if ($(".ctr-custom_charts").length == 0) { return }
  if (typeof Chart === "undefined") { return }

  const root = document.querySelector("[data-cc-view]")
  if (!root) { return }

  const view = root.dataset.ccView            // "show" | "editor"
  const endpoint = root.dataset.ccEndpoint
  const canvas = root.querySelector("[data-cc-canvas]")
  let chart = null
  let currentPayload = null

  const state = {
    range:  root.dataset.ccRange || "12mo",
    bucket: root.dataset.ccBucket || "month",
    start:  null,
    end:    null,
    window: null,
  }

  function csrfToken() {
    const el = document.querySelector('meta[name="csrf-token"]')
    return el ? el.getAttribute("content") : ""
  }

  function escapeHtml(s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, function(c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]
    })
  }

  function fmtValue(v, unit) {
    if (v === null || v === undefined) { return "—" }
    const n = Number(v)
    if (unit === "$") {
      return "$" + n.toLocaleString(undefined, { minimumFractionDigits: 0, maximumFractionDigits: 2 })
    }
    return n.toLocaleString()
  }

  function isoDate(d) {
    return d.getFullYear() + "-" +
      String(d.getMonth() + 1).padStart(2, "0") + "-" +
      String(d.getDate()).padStart(2, "0")
  }

  function renderStats(payload) {
    const el = root.querySelector("[data-cc-stats]")
    if (!el) { return }
    const s = payload.stats || {}
    const tiles = [
      ["Total", fmtValue(s.total, payload.unit)],
      ["Average", fmtValue(s.average, payload.unit)],
      ["Count", (s.count || 0).toLocaleString()],
    ]
    el.innerHTML = tiles.map(function(t) {
      return '<div class="cc-stat"><div class="cc-stat-value">' + t[1] +
        '</div><div class="cc-stat-label">' + t[0] + "</div></div>"
    }).join("")
  }

  function datasetTotal(ds) {
    return (ds.data || []).reduce(function(sum, pt) {
      if (pt === null || pt === undefined) { return sum }
      const v = typeof pt === "number" ? pt : pt.y
      return sum + (typeof v === "number" ? v : 0)
    }, 0)
  }

  function renderLegend(payload) {
    const el = root.querySelector("[data-cc-legend]")
    if (!el) { return }
    if (!payload.datasets || payload.datasets.length < 2) { el.innerHTML = ""; return }

    // Legend ordering is presentational only — highest total first. The dataset
    // order (and thus chart stacking) is untouched.
    const rows = payload.datasets.slice().sort(function(a, b) { return datasetTotal(b) - datasetTotal(a) })
    el.innerHTML = rows.map(function(ds) {
      return '<div class="cc-legend-row"><span class="cc-swatch" style="background-color:' +
        escapeHtml(ds.color) + '"></span><span class="cc-legend-label">' + escapeHtml(ds.label) +
        '</span><span class="cc-legend-total">' + fmtValue(datasetTotal(ds), payload.unit) + "</span></div>"
    }).join("")
  }

  function buildConfig(payload) {
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

  // Draws a dashed vertical reference line for each marker-query event.
  function markerPlugin(payload) {
    return {
      id: "ccMarkers",
      afterDatasetsDraw: function(c) {
        const marks = payload.markers || []
        if (!marks.length) { return }
        const area = c.chartArea
        const ctx = c.ctx
        ctx.save()
        ctx.strokeStyle = "rgba(250, 178, 25, 0.85)"
        ctx.lineWidth = 1.5
        ctx.setLineDash([5, 4])
        marks.forEach(function(m) {
          const px = markerPx(c, payload, m.ts)
          if (px === null || px < area.left || px > area.right) { return }
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
  function markerPx(c, payload, ms) {
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

  function totalPoints(payload) {
    return (payload.datasets || []).reduce(function(sum, ds) {
      return sum + (ds.data || []).filter(function(pt) {
        if (pt === null || pt === undefined) { return false }
        return typeof pt === "number" ? true : pt.y !== null && pt.y !== undefined
      }).length
    }, 0)
  }

  function setEmpty(msg) {
    const wrapper = canvas.closest(".chart-wrapper")
    if (!wrapper) { return }
    let el = wrapper.querySelector(".cc-empty-overlay")
    if (!el) {
      el = document.createElement("div")
      el.className = "cc-empty-overlay"
      wrapper.appendChild(el)
    }
    el.textContent = msg || ""
    el.style.display = msg ? "flex" : "none"
  }

  function render(payload) {
    currentPayload = payload
    const rangeLabelEl = root.querySelector("[data-cc-range-label]")
    if (rangeLabelEl) { rangeLabelEl.textContent = payload.error ? payload.error : (payload.range_label || "") }
    if (payload.window) { state.window = payload.window }
    renderStats(payload)
    renderLegend(payload)

    if (payload.error) {
      setEmpty(payload.error)
    } else if (totalPoints(payload) === 0) {
      setEmpty("No matching events for this filter and range.")
    } else {
      setEmpty(null)
    }

    if (chart) { chart.destroy() }
    chart = new Chart(canvas, buildConfig(payload))
  }

  // Hover a marker line to reveal the underlying event's name/date/notes. Chart.js
  // tooltips don't cover custom-drawn lines, so this is a lightweight own tooltip.
  function setupMarkerHover() {
    const wrapper = canvas.closest(".chart-wrapper")
    if (!wrapper) { return }
    const tip = document.createElement("div")
    tip.className = "cc-marker-tip"
    wrapper.appendChild(tip)

    canvas.addEventListener("mousemove", function(e) {
      const marks = (currentPayload && currentPayload.markers) || []
      if (!chart || !marks.length) { tip.style.display = "none"; return }

      const rect = canvas.getBoundingClientRect()
      const mx = e.clientX - rect.left
      const my = e.clientY - rect.top
      const area = chart.chartArea
      if (my < area.top || my > area.bottom) { tip.style.display = "none"; return }

      let hit = null
      let hitPx = null
      for (let i = 0; i < marks.length; i++) {
        const px = markerPx(chart, currentPayload, marks[i].ts)
        if (px !== null && Math.abs(mx - px) <= 6) { hit = marks[i]; hitPx = px; break }
      }
      if (!hit) { tip.style.display = "none"; return }

      const notes = hit.notes ? "<br>" + escapeHtml(hit.notes) : ""
      tip.innerHTML = "<strong>" + escapeHtml(hit.name) + "</strong><br>" + escapeHtml(hit.date) + notes
      tip.style.display = "block"
      tip.style.left = (canvas.offsetLeft + hitPx + 8) + "px"
      tip.style.top = (canvas.offsetTop + my) + "px"
    })
    canvas.addEventListener("mouseleave", function() { tip.style.display = "none" })
  }
  setupMarkerHover()

  function overrideParams() {
    const p = new URLSearchParams()
    if (state.start && state.end) {
      p.set("start_date", state.start)
      p.set("end_date", state.end)
    } else if (state.range) {
      p.set("range", state.range)
    }
    if (state.bucket) { p.set("bucket", state.bucket) }
    return p
  }

  function fetchShow() {
    fetch(endpoint + "?" + overrideParams().toString(), { headers: { Accept: "application/json" } })
      .then(function(r) { return r.json() })
      .then(render)
  }

  function fetchPreview(form) {
    const fd = new FormData(form)
    const body = new URLSearchParams()
    fd.forEach(function(v, k) {
      // Drop Rails' method-override so the edit form's PATCH doesn't hijack the
      // preview POST route.
      if (k === "_method") { return }
      body.append(k, v)
    })

    fetch(endpoint, {
      method: "POST",
      headers: {
        Accept: "application/json",
        "Content-Type": "application/x-www-form-urlencoded",
        "X-CSRF-Token": csrfToken(),
      },
      body: body.toString(),
    }).then(function(r) { return r.json() }).then(render)
  }

  // ---- Show: initial payload + live controls ----
  if (view === "show") {
    const payloadEl = document.querySelector("[data-cc-payload]")
    const initial = payloadEl ? JSON.parse(payloadEl.textContent) : null

    const bucketSel = root.querySelector("[data-cc-bucket-select]")
    if (bucketSel) { bucketSel.value = state.bucket }

    const dateStart = root.querySelector("[data-cc-date-start]")
    const dateEnd = root.querySelector("[data-cc-date-end]")

    function markActiveRange() {
      root.querySelectorAll("[data-cc-range-btn]").forEach(function(btn) {
        btn.classList.toggle("active", !state.start && btn.dataset.ccRangeBtn === state.range)
      })
    }

    // Reflect the resolved window in the date inputs so the user sees the active
    // span (whether it came from a preset, nav shift, or a custom range).
    function syncDateInputs() {
      if (!state.window) { return }
      if (dateStart) { dateStart.value = isoDate(new Date(state.window.start)) }
      if (dateEnd) { dateEnd.value = isoDate(new Date(state.window.end)) }
    }

    const baseRender = render
    render = function(payload) {
      baseRender(payload)
      syncDateInputs()
    }

    markActiveRange()
    if (initial) { render(initial) }

    root.querySelectorAll("[data-cc-range-btn]").forEach(function(btn) {
      btn.addEventListener("click", function() {
        state.range = btn.dataset.ccRangeBtn
        state.start = null
        state.end = null
        markActiveRange()
        fetchShow()
      })
    })

    if (bucketSel) {
      bucketSel.addEventListener("change", function() {
        state.bucket = bucketSel.value
        fetchShow()
      })
    }

    function applyDateRange() {
      if (!dateStart || !dateEnd || !dateStart.value || !dateEnd.value) { return }
      // Guard against an inverted range; the picker leaves both editable.
      if (dateStart.value > dateEnd.value) { return }
      state.start = dateStart.value
      state.end = dateEnd.value
      markActiveRange()
      fetchShow()
    }
    if (dateStart) { dateStart.addEventListener("change", applyDateRange) }
    if (dateEnd) { dateEnd.addEventListener("change", applyDateRange) }

    root.querySelectorAll("[data-cc-nav]").forEach(function(btn) {
      btn.addEventListener("click", function() {
        if (!state.window) { return }
        const span = state.window.end - state.window.start + 86400000
        const dir = btn.dataset.ccNav === "prev" ? -1 : 1
        state.start = isoDate(new Date(state.window.start + dir * span))
        state.end = isoDate(new Date(state.window.end + dir * span))
        markActiveRange()
        fetchShow()
      })
    })
  }

  // ---- Editor: live preview from the form config ----
  if (view === "editor") {
    const form = root.querySelector("[data-cc-form]")
    if (form) {
      let timer = null
      function schedulePreview() {
        clearTimeout(timer)
        timer = setTimeout(function() { fetchPreview(form) }, 350)
      }
      form.addEventListener("input", schedulePreview)
      form.addEventListener("change", schedulePreview)
      fetchPreview(form)
    }
  }
})
