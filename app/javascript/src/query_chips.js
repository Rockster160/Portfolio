// Chips and a search bar as one control.
//
// A chip writes its own term into the bar, the bar decides which chips are lit,
// and neither one re-runs anything — pressing Search is still what asks the
// server. That means a query typed or pasted by hand lights the chips that
// match it immediately, which is the whole point: two ways of saying the same
// thing that can never disagree about what is being asked for.
//
// The algebra below mirrors SystemController#toggled_query term for term. The
// server still renders the starting state and every chip is still a real link,
// so with this file absent the page behaves exactly as it did before.
//
// Markup contract:
//   [data-query-scope]  the region a bar and its chips share (defaults to document)
//   [data-query-input]  the search field
//   [data-query-chip]   a chip, carrying data-query-field and data-query-value
//   data-query-on       class to toggle for a lit chip (default "is-on")

const VALUE = "(?:\"[^\"]*\"|'[^']*'|[^\\s)]+)"

// A `-` or `NOT` prefix is part of the term so removing one takes the negation
// with it, but see selectedValues: a negated term names something to EXCLUDE
// and is not a selection.
function fieldTerm(field) {
  return `(?:NOT\\s+|-)?${field}:${VALUE}`
}

function selectedValues(query, field) {
  const rx = new RegExp(`(?:^|[\\s(])${field}:(?:"([^"]*)"|'([^']*)'|([^\\s)]+))`, "gi")
  const found = []
  let match
  while ((match = rx.exec(query)) !== null) {
    found.push((match[1] || match[2] || match[3] || "").toLowerCase())
  }
  return found
}

// Taken out WHOLE — removing the terms and leaving the parentheses and the ORs
// behind would not parse.
function withoutClause(query, field) {
  const term = fieldTerm(field)
  const grouped = new RegExp(`\\(\\s*${term}(?:\\s+OR\\s+${term})*\\s*\\)`, "gi")
  const lone = new RegExp(`(?:^|\\s)${term}`, "gi")

  return query.replace(grouped, " ").replace(lone, " ").replace(/\s+/g, " ").trim()
}

function clauseFor(field, values) {
  const terms = values.map((value) => `${field}:${/\s/.test(value) ? JSON.stringify(value) : value}`)
  if (terms.length === 0) return ""
  if (terms.length === 1) return terms[0]

  return `(${terms.join(" OR ")})`
}

function toggledQuery(query, field, value, options) {
  const picked = selectedValues(query, field)
  const wanted = value.toLowerCase()
  const next = picked.includes(wanted) ? picked.filter((v) => v !== wanted) : picked.concat(wanted)
  // Intersected with what the page is currently offering, in its order: a value
  // no longer on screen can't be clicked off, so carrying it forward would
  // strand the filter.
  const ordered = options.filter((option) => next.includes(option.toLowerCase()))

  return [withoutClause(query, field), clauseFor(field, ordered)].filter(Boolean).join(" ")
}

function scopeOf(el) {
  return el.closest("[data-query-scope]") || document
}

function chipsIn(scope) {
  return Array.from(scope.querySelectorAll("[data-query-chip]"))
}

function optionsFor(scope, field) {
  return chipsIn(scope)
    .filter((chip) => chip.dataset.queryField === field)
    .map((chip) => chip.dataset.queryValue)
}

function paint(scope) {
  const input = scope.querySelector("[data-query-input]")
  if (!input) return

  const perField = {}
  chipsIn(scope).forEach((chip) => {
    const field = chip.dataset.queryField
    if (!perField[field]) perField[field] = selectedValues(input.value, field)

    const on = perField[field].includes((chip.dataset.queryValue || "").toLowerCase())
    chip.classList.toggle(chip.dataset.queryOn || "is-on", on)
    chip.setAttribute("aria-pressed", on ? "true" : "false")
  })

  // The list below is still answering the previous question until Search is
  // pressed, and saying so is cheaper than letting it look current.
  const initial = input.dataset.queryInitial
  if (initial === undefined) return

  const dirty = input.value.trim() !== initial.trim()
  const holder = scope === document ? document.body : scope
  holder.classList.toggle("query-dirty", dirty)

  // Greyed out when there is nothing to re-run, which also makes it obvious
  // that pressing it is what applies a change. Disabled from HERE and never in
  // the markup: with this file absent the button has to stay a working submit.
  const submit = scope.querySelector("[data-query-submit]")
  if (submit) submit.disabled = !dirty
}

// Writes a chip's term into the bar. Exported because a chip is not always a
// plain link: a bank account is a whole table row whose name cell is editable
// and whose kind cell is a dropdown, so that page decides for itself which
// clicks mean "filter" and calls this only for those.
function apply(chip) {
  const scope = scopeOf(chip)
  const input = scope.querySelector("[data-query-input]")
  if (!input) return false

  const field = chip.dataset.queryField
  input.value = toggledQuery(input.value, field, chip.dataset.queryValue, optionsFor(scope, field))
  paint(scope)
  return true
}

window.queryChips = { apply, paint, selectedValues, toggledQuery }

document.addEventListener("click", (event) => {
  const chip = event.target.closest?.("[data-query-chip]")
  if (!chip || chip.hasAttribute("data-query-manual")) return
  if (!scopeOf(chip).querySelector("[data-query-input]")) return

  event.preventDefault()
  apply(chip)
})

// `input` rather than `keyup`, so a paste, an undo and a cleared field all
// count the same as typing.
document.addEventListener("input", (event) => {
  if (!event.target.matches?.("[data-query-input]")) return

  paint(scopeOf(event.target))
})

function paintAll() {
  document.querySelectorAll("[data-query-input]").forEach((input) => paint(scopeOf(input)))
}

// A deferred bundle can evaluate after DOMContentLoaded has already gone, and
// then the listener alone never runs.
if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", paintAll)
} else {
  paintAll()
}
