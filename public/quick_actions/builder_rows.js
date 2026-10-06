// Row rendering shared by the meal and list builders. Rows are keyed and
// updated in place, so a sync never rebuilds the grid out from under a tap.

export const fuzzyMatch = (needle, hay) => {
  if (!needle) return true
  let i = 0, j = 0
  const n = needle.toLowerCase(), h = hay.toLowerCase()
  while (i < n.length && j < h.length) { if (n[i] === h[j]) i++; j++ }
  return i === n.length
}

export const splitGraphemes = s => {
  if (window.Intl && Intl.Segmenter) {
    const seg = new Intl.Segmenter(undefined, { granularity: "grapheme" })
    return Array.from(seg.segment(s), x => x.segment)
  }
  return Array.from(s)
}

export const buildRow = () => {
  const row = document.createElement("div")
  row.className = "brow"
  row.innerHTML = `
    <div class="brow-body">
      <div class="brow-icon"></div>
      <div class="brow-text">
        <div class="brow-badges"></div>
        <div class="brow-title"></div>
        <div class="brow-desc"></div>
      </div>
      <div class="brow-stepper">
        <button type="button" class="brow-step" data-step="-1" aria-label="One less">−</button>
        <span class="brow-count">0</span>
        <button type="button" class="brow-step" data-step="1" aria-label="One more">+</button>
        <span class="brow-step brow-edit-hint" aria-hidden="true">✏️</span>
      </div>
    </div>
  `
  return row
}

export const setText = (el, text) => {
  if (el.textContent !== text) el.textContent = text
}

export const setIcon = (row, img, fallback) => {
  const raw = (img || "").trim() || fallback
  if (row.dataset.icon === raw) return
  row.dataset.icon = raw

  const box = row.querySelector(".brow-icon")
  box.replaceChildren()
  if (/^(https?:|\/)/.test(raw)) {
    const el = document.createElement("img")
    el.src = raw
    el.alt = ""
    box.appendChild(el)
    return
  }
  const emoji = document.createElement("i")
  emoji.className = "emoji"
  splitGraphemes(raw).forEach(g => {
    const span = document.createElement("span")
    span.textContent = g
    emoji.appendChild(span)
  })
  box.appendChild(emoji)
}

// `badges` is a list of { text, tone } where tone is ok, warn or bad.
export const setBadges = (row, badges = []) => {
  const box = row.querySelector(".brow-badges")
  const sig = JSON.stringify(badges)
  if (box.dataset.sig === sig) return
  box.dataset.sig = sig

  box.replaceChildren()
  badges.forEach(({ text, tone }) => {
    const badge = document.createElement("span")
    badge.className = `brow-badge ${tone || ""}`
    badge.textContent = text
    box.appendChild(badge)
  })
}

export const setDesc = (row, text) => setText(row.querySelector(".brow-desc"), text || "")

export const setCount = (row, count) => {
  setText(row.querySelector(".brow-count"), String(count))
  row.querySelector('[data-step="-1"]').disabled = count <= 0
}

// Lays out one row per entry in order: new keys get a fresh row, gone keys
// lose theirs, and every other row is updated where it stands and only moved
// when it is out of place.
export const reconcileRows = (container, rows, entries, update) => {
  const seen = new Set()
  let prev = null
  entries.forEach(({ key, item, hidden }) => {
    let row = rows.get(key)
    if (!row) {
      row = buildRow()
      row.dataset.key = key
      rows.set(key, row)
    }
    update(row, item)
    row.classList.toggle("hidden", !!hidden)
    const slot = prev ? prev.nextElementSibling : container.firstElementChild
    if (slot !== row) container.insertBefore(row, slot)
    prev = row
    seen.add(key)
  })
  for (const [key, row] of rows) {
    if (seen.has(key)) continue
    row.remove()
    rows.delete(key)
  }
}

// Drag-to-reorder for edit mode. `onDrop` receives every row key in its new
// order, hidden rows included.
export const enableDragReorder = (container, { isActive, onDrop }) => {
  let dragged = null
  let placeholder = null

  container.addEventListener("dragstart", e => {
    const row = e.target.closest?.(".brow")
    if (!row || !isActive()) return
    dragged = row
    row.classList.add("dragging")
    placeholder = document.createElement("div")
    placeholder.className = "brow-placeholder"
    placeholder.style.height = `${row.offsetHeight}px`
    container.insertBefore(placeholder, row.nextSibling)
  })

  container.addEventListener("dragover", e => {
    if (!dragged) return
    e.preventDefault()
    const row = e.target.closest?.(".brow")
    if (!row || row === dragged) return
    const rect = row.getBoundingClientRect()
    const before = (e.clientY - rect.top) < rect.height / 2
    container.insertBefore(placeholder, before ? row : row.nextSibling)
  })

  container.addEventListener("dragend", () => {
    if (!dragged) return
    const keys = []
    Array.from(container.children).forEach(el => {
      if (el === placeholder) keys.push(dragged.dataset.key)
      else if (el !== dragged && el.dataset.key) keys.push(el.dataset.key)
    })
    dragged.classList.remove("dragging")
    placeholder.remove()
    dragged = null
    placeholder = null
    onDrop(keys)
  })
}
