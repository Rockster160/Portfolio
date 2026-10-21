// The shared icon square, its picker and its cropper, for pages that don't
// load application.js — the meal and list builders run on the quick-actions
// layout, whose scripts are plain modules under public/ and can't import from
// the bundle. This puts what they need on `window.IconField` (and the cropper
// on `window.IconCropper`, which `icon_cropper.js` sets itself).
//
// An image dropped on the square goes through the cropper when the page
// renders `shared/icon_cropper`, and is stored as a `hicon:` household icon —
// the same as from the chores form.
import { bindIconStack } from "./src/icon_stack"
import { renderIconValue, loadIconPool, onIconPoolChanged } from "./src/icon_picker"

// Pulls the pool too, so a stored `hicon:` resolves in the square.
function bindIconField(stack) {
  const bound = bindIconStack(stack)
  loadIconPool().then(() => bound?.render())
  return bound
}

window.IconField = { bindIconField, renderIconValue, loadIconPool, onIconPoolChanged }
