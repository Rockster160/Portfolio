// Dropping a file onto a form.
//
// The `<input type="file">` inside the zone still works on its own, so none of
// this is load-bearing — it is the gesture everybody tries first, plus the
// three things that make it usable:
//
//   * every zone on the page lights up while a file is anywhere over the
//     window, so there is no guessing where it is supposed to go. "If I can,
//     it's not clear that I can or where I should drop it."
//   * a zone inside a collapsed <details> OPENS, because a section that holds
//     no uploads yet is closed, and you cannot drop onto something you cannot
//     see.
//   * a drop that MISSES does nothing, instead of navigating the browser away
//     to the file — which is what a page does when nobody cancels the default.
//
// Mount it on a container: every `[data-drop]` inside is wired, and the
// document-level handlers are installed once.

const FILES = "Files";

function dragsFiles(event) {
  const kinds = event.dataTransfer && event.dataTransfer.types;
  return !!kinds && Array.from(kinds).indexOf(FILES) !== -1;
}

function eat(event) {
  event.preventDefault();
  if (event.stopPropagation) { event.stopPropagation(); }
}

function wireZone(zone) {
  const input = zone.querySelector("input[type=file]");
  if (!input) { return false; }

  const got = zone.querySelector("[data-drop-got]");

  const said = function () {
    const file = input.files && input.files[0];
    if (got) { got.textContent = file ? file.name : ""; }
    zone.classList.toggle("got", !!file);
  };

  input.addEventListener("change", said);

  ["dragenter", "dragover"].forEach(function (name) {
    zone.addEventListener(name, function (event) {
      eat(event);
      zone.classList.add("over");
    });
  });

  zone.addEventListener("dragleave", function (event) {
    eat(event);
    zone.classList.remove("over");
  });

  zone.addEventListener("drop", function (event) {
    eat(event);
    zone.classList.remove("over");
    const files = event.dataTransfer && event.dataTransfer.files;
    if (!files || !files.length) { return; }

    input.files = files;
    said();
  });

  return true;
}

export function bindDropZones(root, doc) {
  const where = doc || (root && root.ownerDocument) || (typeof document === "undefined" ? null : document);
  const zones = Array.from(root.querySelectorAll("[data-drop]"));
  if (!zones.length || !where) { return 0; }

  zones.forEach(wireZone);

  // COUNTED RATHER THAN TOGGLED. Dragging across a child element fires
  // `dragleave` on the parent, so a plain on/off flickers the entire time the
  // file is moving across the page.
  let depth = 0;

  const ready = function (on) {
    zones.forEach(function (zone) {
      zone.classList.toggle("ready", on);
      if (!on) { return; }

      const holder = zone.closest && zone.closest("details");
      if (holder) { holder.open = true; }
    });
  };

  where.addEventListener("dragenter", function (event) {
    if (!dragsFiles(event)) { return; }
    depth += 1;
    ready(true);
  });

  where.addEventListener("dragleave", function () {
    depth = Math.max(0, depth - 1);
    if (depth) { return; }
    ready(false);
  });

  where.addEventListener("dragover", function (event) {
    if (dragsFiles(event)) { event.preventDefault(); }
  });

  where.addEventListener("drop", function (event) {
    if (dragsFiles(event)) { event.preventDefault(); }
    depth = 0;
    ready(false);
    zones.forEach(function (zone) { zone.classList.remove("over"); });
  });

  return zones.length;
}

export default bindDropZones;
