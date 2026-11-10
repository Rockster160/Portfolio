// A prompt slider that is only answered once it's been moved
// (shared/_dynamic_form_fields). It waits greyed out on the last answer with
// no `name`, so a form sent without touching it leaves it out of the response.
// Any touch gives it its name back - a tap that leaves it exactly where it was
// is still someone saying "same as last time".
//
// Delegated from the document because the prompt page re-renders its fields
// after its load step.
function touch(evt) {
  const range = evt.target;
  if (!range.classList?.contains("prompt-range-untouched")) return;

  range.name = range.dataset.name;
  range.classList.remove("prompt-range-untouched");
}

["pointerdown", "keydown", "input"].forEach((type) => {
  document.addEventListener(type, touch, true);
});
