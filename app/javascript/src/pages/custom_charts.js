import { chartConfig as buildConfig, fmtValue, markerColor, markerPx } from "../support/chart_config.js"

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
    const sets = payload.datasets || []
    // One row per marker name, so lines of different colors say what they are.
    const marks = {}
    ;(payload.markers || []).forEach(function(m) { marks[m.name] = markerColor(m) })
    const markRows = Object.keys(marks).map(function(name) {
      return '<div class="cc-legend-row"><span class="cc-swatch cc-swatch-marker" style="border-color:' +
        escapeHtml(marks[name]) + '"></span><span class="cc-legend-label">' + escapeHtml(name) + "</span></div>"
    })
    if (sets.length < 2 && !markRows.length) { el.innerHTML = ""; return }

    // Legend ordering is presentational only — highest total first. The dataset
    // order (and thus chart stacking) is untouched.
    const rows = sets.length < 2 ? [] : sets.slice().sort(function(a, b) { return datasetTotal(b) - datasetTotal(a) })
    el.innerHTML = rows.map(function(ds) {
      return '<div class="cc-legend-row"><span class="cc-swatch" style="background-color:' +
        escapeHtml(ds.color) + '"></span><span class="cc-legend-label">' + escapeHtml(ds.label) +
        '</span><span class="cc-legend-total">' + fmtValue(datasetTotal(ds), payload.unit) + "</span></div>"
    }).concat(markRows).join("")
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
