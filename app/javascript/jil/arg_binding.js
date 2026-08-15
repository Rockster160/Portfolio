// How a function task's args get bound and posted.
//
// Split out of run_args_modal.js because that file imports the whole editor
// (Schema → Sortable and friends), which meant none of this could be exercised
// without a browser. What lives here is the contract between the modal and the
// task: what name an arg is posted under, and what the posted body looks like.
//
// Nothing here touches the DOM beyond `querySelector` on a wrapper.

// The key a declared arg label is posted under. Matches what Buddy sends for
// the same task (call_jil_function: "LOWERCASE_SNAKE_CASE of the arg name"), so
// one task can read one name whichever side called it.
export function argKey(label) {
  return String(label).trim().toLowerCase().replace(/\s+/g, "_")
}

// How one arg gets bound. A quoted label earns a name; anything else stays
// position-only, which is all there is to go on.
//
// This matters more than it looks. `params` is built from the args the caller
// actually SENT, so a caller that skips an optional middle arg shifts every
// later arg onto the wrong name — a camera request for {camera, event} with no
// `when` put the event type into the timestamp slot. An arg that can be asked
// for by its own label is what makes an optional arg safe anywhere but last.
export function bindingFor(declaredLabel) {
  if (!declaredLabel) { return { kind: "positional" } }

  return { kind: "named", name: argKey(declaredLabel) }
}

export function readInputValue(input) {
  if (!input) { return null }
  switch (input.type) {
    case "checkbox": return input.checked
    case "number":
      if (input.value === "") { return null }
      return parseFloat(input.value)
    default:
      return input.dataset.raw || input.value
  }
}

export function findInput(wrapper) {
  if (!wrapper) { return null }
  return wrapper.querySelector(":scope > input, :scope > textarea, :scope > select, :scope > .switch > input")
}

// Build the input_data hash. Every value also goes into `params` (in declaration
// order) so the task can read it via positional `Global.functionParams` /
// `Global.params()` regardless of whether the listener spelled the arg with a
// name. Named args additionally appear at the top level under their name.
//
// `params` is assigned last on purpose: an arg labeled "Params" would otherwise
// eat the positional list and break every positional read in that task.
export function collectValues(fields) {
  const data = {}
  const params = []
  fields.forEach((f) => {
    const value = readInputValue(findInput(f.node))
    if (f.kind === "named") { data[f.name] = value }
    params.push(value)
  })
  if (params.length > 0) { data.params = params }
  return data
}
