// A linear y-axis that cuts out the empty stretch between ordinary values and
// a handful of outliers far above (or below) them. The ordinary values keep
// most of the height; each run of outliers gets a short zone of its own past a
// thin squiggled band, with its true value printed beside it. Nothing about the
// data changes, so tooltips still read the real numbers.
//
// Opt in per axis with `type: "broken"`. When nothing qualifies as an outlier
// the axis is an ordinary linear one. `breakLabels: false` keeps the cut but
// drops the printed values, for a secondary axis whose peak sits on the same
// column as the primary one's.

// The smallest outlier has to be this many times the largest ordinary value
// before cutting is worth the visual oddness of a broken axis.
const OUTLIER_RATIO = 3
// Outliers are the exception: past this share of the points, the "outliers"
// are a second level of normal and cutting them out would hide the shape.
const OUTLIER_SHARE = 0.1
const MIN_POINTS = 5

const GAP_PX = 12
const LABEL_PX = 16
const ZONE_SHARE = 0.12
const ZONE_MIN_PX = 32
const NORMAL_TICK_PX = 40
const ZONE_TICK_PX = 28

const WAVE_LENGTH = 10
const WAVE_HEIGHT = 1.5
const SQUIGGLE_COLOR = "rgba(201, 209, 217, 0.55)"
const LABEL_COLOR = "#C9D1D9"
const FALLBACK_SURFACE = "#161B22"

let registered = false

export function registerBrokenAxis() {
  if (registered || typeof Chart === "undefined") { return }
  registered = true

  class BrokenScale extends Chart.LinearScale {
    static id = "broken"

    determineDataLimits() {
      super.determineDataLimits()
      this._breakExtents = extentsFor(this)
    }

    // Runs again on every layout pass with the height that pass settled on, so
    // the zones are sized against the final axis length.
    buildTicks() {
      const ticks = super.buildTicks()
      this._breakPlan = plannable(this) ? planBreaks(this._breakExtents, {
        length:    Math.abs(this.height),
        precision: this.options.ticks.precision,
      }) : null
      if (this._breakPlan && this.options.breakLabels === false) { this._breakPlan.labels = [] }
      if (!this._breakPlan) { return ticks }

      this.min = this.start = this._breakPlan.min
      this.max = this.end = this._breakPlan.max
      return this._breakPlan.ticks.map(function(value) { return { value: value } })
    }

    getPixelForValue(value) {
      if (!this._breakPlan) { return super.getPixelForValue(value) }
      if (value === null || !Number.isFinite(value)) { return NaN }
      return this.getPixelForDecimal(interpolate(this._breakPlan.knots, value, 0, 1))
    }

    getValueForPixel(pixel) {
      if (!this._breakPlan) { return super.getValueForPixel(pixel) }
      return interpolate(this._breakPlan.knots, this.getDecimalForPixel(pixel), 1, 0)
    }
  }

  Chart.register(BrokenScale, breakPlugin)
}

function plannable(scale) {
  const bounds = scale.getUserBounds()
  return !scale.isHorizontal() && scale.options.beginAtZero && !scale.options.reverse &&
    !bounds.minDefined && !bounds.maxDefined
}

// What the axis has to reach at each column: the top and bottom of every
// stack, or every point on its own when the series don't stack. Each extent
// remembers the dataset drawn at its tip, so a label lands over the right bar
// when stack groups sit side by side.
function extentsFor(scale) {
  const highs = []
  const lows = []
  const stacks = new Map()

  scale.chart.getSortedVisibleDatasetMetas().forEach(function(meta) {
    if (meta.vScale !== scale) { return }
    const stackKey = meta.stack || meta.type
    ;(meta._parsed || []).forEach(function(point, index) {
      const value = point && point[scale.axis]
      if (!Number.isFinite(value)) { return }

      if (!meta._stacked) {
        (value < 0 ? lows : highs).push({ value: value, index: index, meta: meta })
        return
      }

      const key = index + "|" + stackKey
      const stack = stacks.get(key) || { index: index, pos: null, neg: null }
      stacks.set(key, stack)
      const side = value < 0 ? "neg" : "pos"
      if (!stack[side]) { stack[side] = { value: 0, index: index, meta: meta } }
      stack[side].value += value
      stack[side].meta = meta
    })
  })

  stacks.forEach(function(stack) {
    if (stack.pos) { highs.push(stack.pos) }
    if (stack.neg) { lows.push(stack.neg) }
  })
  return { highs: highs, lows: lows }
}

// The cut, in value space, from the extents. Exported apart from the scale so
// the arithmetic can be reasoned about without a canvas.
//
// The headroom for labels is reserved whether or not they're drawn, so two
// axes cut on the same chart put their bands at the same height.
export function planBreaks(extents, options) {
  const high = outliersIn(extents.highs.map(function(e) { return { value: e.value, extent: e } }))
  const low = outliersIn(extents.lows.map(function(e) { return { value: -e.value, extent: e } }))
  if (!high && !low) { return null }

  // A short chart can't spare room for a zone at both ends, so it cuts only
  // the side where the jump is bigger.
  return layOut(extents, high, low, options) ||
    (high && low && (high.ratio >= low.ratio ?
      layOut(extents, high, null, options) :
      layOut(extents, null, low, options)))
}

function layOut(extents, high, low, options) {
  const length = options.length
  const labelPx = LABEL_PX
  const zonePx = Math.max(ZONE_MIN_PX, length * ZONE_SHARE)
  const sidePx = zonePx + GAP_PX + labelPx
  const normalPx = length - (high ? sidePx : 0) - (low ? sidePx : 0)
  if (normalPx < length * 0.5) { return null }

  const lowest = Math.min(0, ...extents.lows.map(function(e) { return e.value }))
  const highest = Math.max(0, ...extents.highs.map(function(e) { return e.value }))
  const normalLow = low ? -low.normal : lowest
  const normalHigh = high ? high.normal : highest
  if (normalHigh <= normalLow) { return null }

  const tickCount = Math.max(2, Math.floor(normalPx / NORMAL_TICK_PX))
  const step = niceStep(normalHigh - normalLow, tickCount, options.precision)
  const bottom = Math.floor(normalLow / step) * step
  const top = Math.ceil(normalHigh / step) * step
  const ticks = stepsBetween(bottom, top, step, true)

  const knots = []
  const bands = []
  let px = 0
  const at = function(value) { knots.push([value, px / length]) }

  if (low) {
    const zone = outlierZone(low, -bottom, zonePx, options.precision)
    px += labelPx
    at(-zone.top)
    px += zonePx
    at(-zone.bottom)
    bands.push([px / length, (px + GAP_PX) / length])
    px += GAP_PX
    zone.ticks.forEach(function(value) { ticks.push(-value) })
  }

  at(bottom)
  px += normalPx
  at(top)

  if (high) {
    const zone = outlierZone(high, top, zonePx, options.precision)
    bands.push([px / length, (px + GAP_PX) / length])
    px += GAP_PX
    at(zone.bottom)
    px += zonePx
    at(zone.top)
    zone.ticks.forEach(function(value) { ticks.push(value) })
  }

  const labels = [].concat(
    high ? high.points.map(function(e) { return { extent: e, side: 1 } }) : [],
    low ? low.points.map(function(e) { return { extent: e, side: -1 } }) : [],
  )

  return {
    knots:  knots,
    bands:  bands,
    labels: labels,
    ticks:  ticks.sort(function(a, b) { return a - b }),
    min:    interpolate(knots, 0, 1, 0),
    max:    interpolate(knots, 1, 1, 0),
  }
}

// The biggest jump among the top few values, as long as it is big enough.
// `entries` are magnitudes, so the same search finds outliers below zero.
function outliersIn(entries) {
  if (entries.length < MIN_POINTS) { return null }

  const sorted = entries.slice().sort(function(a, b) { return b.value - a.value })
  const most = Math.max(1, Math.floor(sorted.length * OUTLIER_SHARE))
  let best = null
  for (let k = 1; k <= most && k < sorted.length; k++) {
    const rest = sorted[k].value
    if (rest <= 0) { break }
    const ratio = sorted[k - 1].value / rest
    if (ratio >= OUTLIER_RATIO && (!best || ratio > best.ratio)) { best = { ratio: ratio, k: k } }
  }
  if (!best) { return null }

  return {
    ratio:    best.ratio,
    points:   sorted.slice(0, best.k).map(function(e) { return e.extent }),
    normal:   sorted[best.k].value,
    smallest: sorted[best.k - 1].value,
    largest:  sorted[0].value,
  }
}

// The outliers' own stretch of axis, as magnitudes. It starts a little below
// the smallest outlier so even that one shows a real length of bar past the
// cut, and never below the top of the ordinary range.
function outlierZone(found, floor, zonePx, precision) {
  const pad = Math.max((found.largest - found.smallest) * 0.25, found.largest * 0.1)
  const count = Math.max(1, Math.floor(zonePx / ZONE_TICK_PX))
  const step = niceStep(found.largest - found.smallest + pad, count, precision)
  const top = Math.ceil(found.largest / step) * step
  const bottom = Math.max(floor, Math.floor((found.smallest - pad) / step) * step)
  // The zone's own bottom edge sits against the cut, right over the top tick
  // of the ordinary range, so it goes unlabeled.
  return { top: top, bottom: bottom, ticks: stepsBetween(bottom, top, step, false) }
}

function niceStep(range, count, precision) {
  const raw = range / count
  const magnitude = Math.pow(10, Math.floor(Math.log10(raw)))
  const fraction = raw / magnitude
  const nice = fraction <= 1 ? 1 : fraction <= 2 ? 2 : fraction <= 5 ? 5 : 10
  const step = nice * magnitude
  return Number.isInteger(precision) ? Math.max(step, Math.pow(10, -precision)) : step
}

function stepsBetween(bottom, top, step, includeBottom) {
  const values = []
  const first = includeBottom ? bottom : bottom + step
  for (let value = first; value <= top + step / 1000; value += step) {
    values.push(Number(value.toPrecision(12)))
  }
  return values
}

// Piecewise-linear lookup through [value, decimal] knots, reading column
// `from` and answering in column `to`. Past either end it carries on along the
// last segment's slope, which is what fills the label headroom.
function interpolate(knots, input, from, to) {
  let i = 1
  while (i < knots.length - 1 && input > knots[i][from]) { i++ }
  const a = knots[i - 1]
  const b = knots[i]
  const span = b[from] - a[from]
  if (span === 0) { return b[to] }
  return a[to] + (input - a[from]) / span * (b[to] - a[to])
}

// --- Drawing ---------------------------------------------------------------

const breakPlugin = {
  id: "brokenAxis",
  afterDatasetsDraw: function(chart) {
    const scales = Object.values(chart.scales).filter(function(scale) { return scale._breakPlan })
    if (!scales.length) { return }

    const ctx = chart.ctx
    ctx.save()
    drawBands(chart, scales)
    drawLabels(chart, scales)
    ctx.restore()
  },
}

// The band is painted in the surface color over everything drawn so far, so a
// bar or line crossing it reads as cut rather than squeezed.
function drawBands(chart, scales) {
  const ctx = chart.ctx
  const area = chart.chartArea
  const drawn = new Set()
  const surface = surfaceColor(chart)

  scales.forEach(function(scale) {
    scale._breakPlan.bands.forEach(function(band) {
      const top = Math.min(scale.getPixelForDecimal(band[0]), scale.getPixelForDecimal(band[1]))
      const bottom = Math.max(scale.getPixelForDecimal(band[0]), scale.getPixelForDecimal(band[1]))
      const key = Math.round(top) + ":" + Math.round(bottom)
      if (drawn.has(key)) { return }
      drawn.add(key)

      ctx.fillStyle = surface
      ctx.fillRect(area.left, top, area.right - area.left, bottom - top)
      ctx.strokeStyle = SQUIGGLE_COLOR
      ctx.lineWidth = 1.25
      squiggle(ctx, area.left, area.right, top + WAVE_HEIGHT)
      squiggle(ctx, area.left, area.right, bottom - WAVE_HEIGHT)
    })
  })
}

function squiggle(ctx, left, right, y) {
  ctx.beginPath()
  for (let x = left; x <= right; x += 2) {
    const offset = Math.sin((x - left) / WAVE_LENGTH * Math.PI * 2) * WAVE_HEIGHT
    if (x === left) { ctx.moveTo(x, y + offset) } else { ctx.lineTo(x, y + offset) }
  }
  ctx.stroke()
}

// Each outlier's true value just past its tip. Two labels that would overlap
// (a bar and a line peaking on the same column) step apart instead.
function drawLabels(chart, scales) {
  const ctx = chart.ctx
  const placed = []
  const surface = surfaceColor(chart)
  ctx.font = "600 11px " + Chart.defaults.font.family
  ctx.textAlign = "center"
  ctx.textBaseline = "middle"

  scales.forEach(function(scale) {
    scale._breakPlan.labels.forEach(function(label) {
      const element = label.extent.meta.data[label.extent.index]
      if (!element) { return }

      const text = formatLabel(scale, label.extent.value)
      const width = ctx.measureText(text).width + 6
      const x = element.x
      let y = scale.getPixelForValue(label.extent.value) - label.side * LABEL_PX / 2
      while (placed.some(function(box) { return overlaps(box, x, y, width) })) {
        y -= label.side * LABEL_PX
      }
      placed.push({ x: x, y: y, width: width })
      // On the surface color, so a line peaking on the same column passes
      // behind the number instead of through it.
      ctx.fillStyle = surface
      ctx.fillRect(x - width / 2, y - LABEL_PX / 2 + 1, width, LABEL_PX - 2)
      ctx.fillStyle = LABEL_COLOR
      ctx.fillText(text, x, y)
    })
  })
}

function overlaps(box, x, y, width) {
  return Math.abs(box.x - x) < (box.width + width) / 2 && Math.abs(box.y - y) < LABEL_PX
}

// The axis's own tick format, so the label reads like the numbers beside it.
function formatLabel(scale, value) {
  const callback = scale.options.ticks.callback
  const text = callback ? callback.call(scale, value, 0, scale.ticks) : value
  return Array.isArray(text) ? text.join(" ") : String(text)
}

// The first painted background behind the canvas, since the canvas itself is
// transparent and the band has to match whatever surface it sits on.
function surfaceColor(chart) {
  if (chart.$brokenAxisSurface) { return chart.$brokenAxisSurface }
  let color = FALLBACK_SURFACE
  for (let el = chart.canvas; el; el = el.parentElement) {
    const background = getComputedStyle(el).backgroundColor
    if (background && background !== "transparent" && !/rgba\(.*,\s*0\)$/.test(background)) {
      color = background
      break
    }
  }
  chart.$brokenAxisSurface = color
  return color
}
