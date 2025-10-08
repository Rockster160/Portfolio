import { hideModal } from "./modal.js";
import { showFlash } from "./flash.js";

const loadInventory = () => {
  const tree = document.querySelector(".tree");
  const searchWrapper = document.querySelector(".search-wrapper");
  const inventoryForm = document.querySelector(".inventory-inline-form");
  const searchField = inventoryForm.querySelector("#new_box_name");
  const editModalBtn = document.querySelector(".edit-button");
  const editModal = document.querySelector("#edit-modal");
  const editBoxForm = document.querySelector("#editBoxForm");

  function upsertBox(box) {
    const existingLi = tree.querySelector(`li[data-id='${box.id}']`);
    if (existingLi) {
      if (box.deleted) {
        const parentLi = existingLi.closest(
          `li[data-id='${existingLi.dataset.parentId}']`,
        );
        const ul = parentLi
          ? parentLi.querySelector(`ul[data-box-id='${parentLi.dataset.id}']`)
          : null;
        existingLi.remove();
        if (ul && !ul.querySelector("li[data-type]")) {
          updateBoxType(parentLi);
        }
        return;
      }

      const oldHierarchy = existingLi.dataset.hierarchy || "";
      const oldParentId = existingLi.dataset.parentId || "";

      if (!isRootLi(existingLi)) {
        existingLi.dataset.type = box.empty ? "item" : "box";
      }
      existingLi.dataset.sortOrder = box.sort_order;
      existingLi.querySelector(".item-name").innerText = box.name;
      existingLi.querySelector(".item-notes").innerText = box.notes || "";
      existingLi.querySelector(".item-description").innerText =
        box.description || "";
      existingLi.dataset.hierarchy = box.hierarchy;
      existingLi.dataset.parentId = box.parent_id || "";

      if (oldParentId !== (box.parent_id || "")) {
        const oldParent =
          tree.querySelector(`li[data-id='${oldParentId}']`) || null;
        const newParent =
          tree.querySelector(`li[data-id='${box.parent_id}']`) ||
          tree.querySelector("li[data-type='root']");
        updateBoxType(oldParent);
        updateBoxType(newParent);
      }

      if (oldHierarchy && oldHierarchy !== box.hierarchy) {
        propagateHierarchyChange(existingLi, oldHierarchy, box.hierarchy);
      }

      return;
    }

    const template = inventoryForm.querySelector("#box-template");
    if (box && template) {
      const clone = template.content.cloneNode(true);
      const li = clone.querySelector("li");
      li.dataset.id = box.id;
      li.dataset.hierarchy = box.hierarchy;
      li.dataset.parentId = box.parent_id || "";
      li.querySelector(".item-name").innerText = box.name;
      li.querySelector(".item-notes").innerText = box.notes || "";
      li.querySelector(".item-description").innerText = box.description || "";
      li.querySelector("ul[data-box-id='']").dataset.boxId = box.id;
      li.dataset.type = box.empty ? "item" : "box";

      const parentLi = tree.querySelector(`li[data-id='${box.parent_id}']`);
      const ul = parentLi
        ? parentLi.querySelector(`ul[data-box-id='${box.parent_id}']`)
        : tree.querySelector("ul[role=tree]");

      if (ul) {
        if (parentLi) {
          parentLi.querySelector(".empty-box")?.remove();
          updateBoxType(parentLi);
          ul.prepend(clone);
        } else {
          ul.querySelector("[data-type=root]").after(clone);
        }
        attachDetailsToggleListeners();
        ensureDraggableRoots();
        updateBoxType(parentLi);
        li.scrollIntoView({ behavior: "smooth", block: "center" });
      }
    }
  }

  function updateBoxType(li) {
    if (!li || isRootLi(li)) return;
    const ul = targetUlFor(li);
    const hasKids = !!ul && ul.querySelector("li[data-type]");
    li.dataset.type = hasKids ? "box" : "item";

    if (!ul) return;
    if (!hasKids && !ul.querySelector(".empty-box")) {
      const emptyLi = document.createElement("li");
      emptyLi.classList.add("empty-box");
      emptyLi.innerHTML = "• &lt;empty&gt;";
      ul.appendChild(emptyLi);
    } else if (hasKids) {
      ul.querySelector(".empty-box")?.remove();
    }
  }

  function propagateHierarchyChange(parentLi, oldH, newH) {
    if (!parentLi || !oldH || !newH || oldH === newH) return;
    const prefix = `${oldH} > `;
    const walker = document.createTreeWalker(
      parentLi,
      NodeFilter.SHOW_ELEMENT,
      {
        acceptNode: (node) =>
          node.matches?.("li[data-type]")
            ? NodeFilter.FILTER_ACCEPT
            : NodeFilter.FILTER_SKIP,
      },
    );
    // skip the parent itself, start at first child
    walker.nextNode();
    let node = walker.currentNode;
    while (node) {
      const h = node.dataset?.hierarchy || "";
      if (h.startsWith(prefix)) {
        node.dataset.hierarchy = `${newH} > ${h.slice(prefix.length)}`;
      }
      node = walker.nextNode();
    }

    // refresh the header if the selected row is inside this subtree
    const selected = document.querySelector("li[data-type].selected");
    if (selected && parentLi.contains(selected)) {
      const codeEl = document.querySelector(".search-wrapper code.hierarchy");
      if (codeEl) codeEl.innerText = selected.dataset.hierarchy || "";
    }
  }

  function slotFromEvent(evt, targetLi) {
    const summary =
      targetLi.querySelector(":scope > details > summary") ||
      targetLi.querySelector(":scope > summary") ||
      targetLi;
    const r = summary.getBoundingClientRect();
    const y = evt.clientY;
    const topBand = r.top + r.height * 0.25;
    const botBand = r.bottom - r.height * 0.25;

    if (y < topBand) return "before";
    if (y > botBand) return "after";
    return "into";
  }

  function siblingIndex(li) {
    const parentUl = li.parentElement;
    const isRootParent = parentUl.matches("ul[role=tree]");
    const rows = [...parentUl.children]
      .filter((n) => n.matches("li[data-type]"))
      .filter((n) => !isRootParent || n.dataset.type !== "root");
    return rows.indexOf(li);
  }

  function isRootLi(li) {
    return !!li && li.dataset?.type === "root";
  }

  function containerRows(containerUl) {
    return [...containerUl.children]
      .filter((n) => n.matches("li[data-type]"))
      .filter((n) => !isRootLi(n));
  }

  function safeInsert(containerUl, node, insertRef, indexHint) {
    if (!containerUl) return;
    let ref =
      insertRef && insertRef.parentElement === containerUl ? insertRef : null;

    if (!ref && Number.isInteger(indexHint)) {
      const rows = containerRows(containerUl);
      const i = Math.max(0, Math.min(indexHint, rows.length));
      ref = rows[i] || null;
    }

    if (ref) containerUl.insertBefore(node, ref);
    else containerUl.appendChild(node);
  }

  function containerDropInfo(evt, containerUl) {
    // parent <li> (or the root <li>)
    const parentLi =
      containerUl.closest("li[data-type]") ||
      document.querySelector(".tree li[data-type='root']");

    // All real rows in this container (exclude root sentinel if top-level)
    const rows = [...containerUl.children]
      .filter((n) => n.matches("li[data-type]"))
      .filter((n) => !isRootLi(n));

    if (rows.length === 0) {
      return { parentLi, insertRef: null, insertAt: 0, y: evt.clientY };
    }

    // find index by mouse vertical midpoints
    const y = evt.clientY;
    let insertAt = rows.length;
    for (let i = 0; i < rows.length; i += 1) {
      const r = rows[i].getBoundingClientRect();
      const mid = r.top + r.height / 2;
      if (y < mid) {
        insertAt = i;
        break;
      }
    }
    const insertRef = rows[insertAt] || null;
    return { parentLi, insertRef, insertAt, y };
  }

  function placeContainerGuide(containerUl, insertAt) {
    // draw a horizontal guide spanning the container
    const guide =
      document.querySelector(".drop-guide") ||
      (() => {
        const g = document.createElement("div");
        g.className = "drop-guide";
        document.body.appendChild(g);
        return g;
      })();

    // choose y from neighbor row or container bounds
    const rows = [...containerUl.children]
      .filter((n) => n.matches("li[data-type]"))
      .filter((n) => !isRootLi(n));

    let y;
    if (rows.length === 0) {
      const cr = containerUl.getBoundingClientRect();
      y = cr.top + 6;
    } else if (insertAt === 0) {
      const r0 = rows[0].getBoundingClientRect();
      y = r0.top - 2;
    } else if (insertAt >= rows.length) {
      const rn = rows[rows.length - 1].getBoundingClientRect();
      y = rn.bottom - 2;
    } else {
      const r = rows[insertAt].getBoundingClientRect();
      y = r.top - 2;
    }

    const wr = containerUl.getBoundingClientRect();
    guide.style.left = `${wr.left}px`;
    guide.style.width = `${wr.width}px`;
    guide.style.top = `${y}px`;
  }

  function targetUlFor(li) {
    if (li.dataset.type === "root") {
      return document.querySelector(".tree ul[role=tree]");
    }
    return (
      li.querySelector(`:scope > details > ul`) ||
      li.querySelector(`ul[data-box-id='${li.dataset.id}']`)
    );
  }

  function canDrop(dragEl, targetLi) {
    if (!dragEl || !targetLi) return false;
    if (targetLi.dataset.type === "root") return true;
    if (targetLi === dragEl) return false;
    if (isDescendant(targetLi, dragEl)) return false;
    return true;
  }

  function buildChildIds(containerUl) {
    return containerRows(containerUl)
      .map((n) => parseInt(n.dataset.id, 10))
      .filter((n) => Number.isFinite(n));
  }

  function isDescendant(child, ancestor) {
    if (!child || !ancestor) return false;
    let n = child.parentElement;
    while (n) {
      if (n === ancestor) return true;
      n = n.parentElement;
    }
    return false;
  }

  function ensureDraggableRoots() {
    document.querySelectorAll(".tree li[data-type]").forEach((li) => {
      if (li.dataset.type === "root") {
        li.removeAttribute("draggable");
      } else if (!li.hasAttribute("draggable")) {
        li.setAttribute("draggable", "true");
      }
    });
  }

  function getDropTarget(el) {
    // only allow dropping into a box (its children ul) or the root
    const li = el?.closest("li[data-type]");
    if (!li) return null;
    if (li.dataset.type === "box" || li.dataset.type === "root") return li;
    return null;
  }

  function moveLiToTarget(li, targetLi) {
    const isRoot = targetLi.dataset.type === "root";
    const targetId = targetLi.dataset.id || "";
    let targetUl;

    if (isRoot) {
      targetUl = tree.querySelector("ul[role=tree]");
      // insert after the root row
      const rootRow = targetUl.querySelector("li[data-type='root']");
      rootRow.after(li);
    } else {
      targetUl =
        targetLi.querySelector(`ul[data-box-id='${targetId}']`) ||
        targetLi.querySelector(":scope > details > ul") ||
        targetLi.querySelector("ul");
      if (!targetUl) return;
      // box now definitely isn't "empty"
      targetLi.querySelector(".empty-box")?.remove();
      targetLi.dataset.type = "box";
      targetUl.appendChild(li);
    }

    // update hierarchy string on the moved li
    const parentHierarchy = isRoot
      ? "Everything"
      : targetLi.dataset.hierarchy || "";
    const name = li.querySelector(".item-name")?.innerText?.trim() || "";
    li.dataset.parentId = targetId;
    li.dataset.hierarchy =
      parentHierarchy && name ? `${parentHierarchy} > ${name}` : name;
  }

  function attachDragAndDrop() {
    ensureDraggableRoots();

    let dragEl = null;
    let guide = null;
    let intoRow = null;

    function rootLi() {
      return document.querySelector(".tree li[data-type='root']");
    }

    function ensureGuide() {
      if (guide) return guide;
      guide = document.createElement("div");
      guide.className = "drop-guide";
      document.body.appendChild(guide);
      return guide;
    }

    function clearGuide() {
      guide?.remove();
      guide = null;
    }

    function setGuideAt(y, left, width) {
      const g = ensureGuide();
      g.style.top = `${y}px`;
      g.style.left = `${left}px`;
      g.style.width = `${width}px`;
    }

    function clearInto() {
      intoRow?.classList.remove("into-target");
      intoRow = null;
    }

    document.addEventListener("dragstart", (evt) => {
      const li = evt.target.closest("li[data-type]");
      if (!li || isRootLi(li)) return;
      dragEl = li;
      li.classList.add("dragging");
      evt.dataTransfer.setData("text/plain", li.dataset.id || "");
      evt.dataTransfer.effectAllowed = "move";
    });

    document.addEventListener("dragend", () => {
      dragEl?.classList.remove("dragging");
      dragEl = null;
      clearInto();
      clearGuide();
    });

    document.addEventListener("dragover", (evt) => {
      if (!dragEl) return;

      // Prefer row targeting (before/after/into)
      const row = evt.target.closest("li[data-type]");
      if (row && row !== dragEl && !row.contains(dragEl)) {
        evt.preventDefault();

        let slot = slotFromEvent(evt, row);
        if (isRootLi(row)) slot = "into"; // root acts like its container top

        const summary =
          row.querySelector(":scope > details > summary") ||
          row.querySelector(":scope > summary") ||
          row;
        const r = summary.getBoundingClientRect();

        if (slot === "before") {
          clearInto();
          setGuideAt(r.top - 2, r.left, r.width);
        } else if (slot === "after") {
          clearInto();
          setGuideAt(r.bottom - 2, r.left, r.width);
        } else {
          clearGuide();
          if (!isRootLi(row)) {
            if (intoRow !== row) {
              clearInto();
              row.classList.add("into-target");
              intoRow = row;
            }
          } else {
            // "into" root → show top-of-top-level line for feedback
            const topUl = document.querySelector(".tree ul[role=tree]");
            const wr = topUl.getBoundingClientRect();
            const firstReal = [...topUl.children].find(
              (n) => n.matches("li[data-type]") && !isRootLi(n),
            );
            const y = firstReal
              ? firstReal.getBoundingClientRect().top - 2
              : wr.top + 6;
            setGuideAt(y, wr.left, wr.width);
          }
        }

        evt.dataTransfer.dropEffect = "move";
        return;
      }

      // Container whitespace: compute index by Y inside the UL
      const ul = evt.target.closest("ul");
      if (ul) {
        const parentLi = ul.closest("li[data-type]") || rootLi();
        if (parentLi && parentLi.contains(dragEl)) return;

        evt.preventDefault();

        const rows = containerRows(ul);
        const wr = ul.getBoundingClientRect();
        const y = evt.clientY;
        let insertAt = rows.length;
        for (let i = 0; i < rows.length; i += 1) {
          const rr = rows[i].getBoundingClientRect();
          if (y < rr.top + rr.height / 2) {
            insertAt = i;
            break;
          }
        }

        const lineY =
          rows.length === 0
            ? wr.top + 6
            : insertAt === 0
            ? rows[0].getBoundingClientRect().top - 2
            : insertAt >= rows.length
            ? rows[rows.length - 1].getBoundingClientRect().bottom - 2
            : rows[insertAt].getBoundingClientRect().top - 2;

        clearInto();
        setGuideAt(lineY, wr.left, wr.width);
        evt.dataTransfer.dropEffect = "move";
      }
    });

    document.addEventListener("drop", (evt) => {
      if (!dragEl) return;
      evt.preventDefault();

      let targetUl, parentLi, insertAt, insertRef;

      const row = evt.target.closest("li[data-type]");
      if (row && row !== dragEl && !row.contains(dragEl)) {
        let slot = slotFromEvent(evt, row);
        if (isRootLi(row)) slot = "into";

        if (slot === "before" || slot === "after") {
          parentLi = row.parentElement.closest("li[data-type]") || rootLi();
          targetUl =
            parentLi.dataset?.type === "root"
              ? document.querySelector(".tree ul[role=tree]")
              : parentLi.querySelector(":scope > details > ul") ||
                parentLi.querySelector(
                  `ul[data-box-id='${parentLi.dataset.id}']`,
                );
          const rows = containerRows(targetUl);
          const idx = rows.indexOf(row);
          insertAt =
            slot === "before"
              ? Math.max(0, idx)
              : Math.min(rows.length, idx + 1);
          insertRef = rows[insertAt] || null;
        } else {
          // INTO row → top of its container
          parentLi = row;
          targetUl = targetUlFor(parentLi);
          if (!targetUl) return;
          const rows = containerRows(targetUl);
          insertAt = 0;
          insertRef = rows[0] || null;
        }
      } else {
        // Container whitespace
        targetUl =
          evt.target.closest("ul") ||
          document.querySelector(".tree ul[role=tree]");
        parentLi = targetUl.closest("li[data-type]") || rootLi();

        const rows = containerRows(targetUl);
        const y = evt.clientY;
        insertAt = rows.length;
        for (let i = 0; i < rows.length; i += 1) {
          const rr = rows[i].getBoundingClientRect();
          if (y < rr.top + rr.height / 2) {
            insertAt = i;
            break;
          }
        }
        insertRef = rows[insertAt] || null;
      }

      // Prevent dropping into own subtree
      if (parentLi && parentLi.contains(dragEl)) return;

      const prevParentLi =
        dragEl.parentElement.closest("li[data-type]") || rootLi();

      // Optimistic move
      safeInsert(targetUl, dragEl, insertRef, insertAt);

      updateBoxType(prevParentLi);
      updateBoxType(parentLi);

      const movedId = dragEl.dataset.id;
      const newParentId = isRootLi(parentLi) ? "" : parentLi.dataset.id || "";
      const child_ids = buildChildIds(targetUl);

      fetch(editBoxForm.action, {
        method: "PATCH",
        headers: {
          accept: "application/json",
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          box_id: movedId,
          parent_id: newParentId,
          child_ids,
        }),
      })
        .then((r) =>
          r.ok ? r.json() : Promise.reject(new Error("Update failed")),
        )
        .then((data) => {
          upsertBox(data.data);
        })
        .catch((err) => {
          showFlash(err.message || "Move failed");
        })
        .finally(() => {
          clearInto();
          clearGuide();
          dragEl?.classList.remove("dragging");
          dragEl = null;
        });
    });

    // --- Touch shim: long-press to start drag on mobile (iOS/Android) ---
    (() => {
      if (!window.matchMedia("(pointer: coarse)").matches) return;

      let touchDrag = false;
      let pressTimer = null;
      let startEl = null;

      const LONG_PRESS_MS = 220;

      const pt = (e) => e.touches?.[0] || e.changedTouches?.[0];

      function handleTouchOver(x, y) {
        // reuse your existing visuals by calling the same logic the mouse path uses
        const el = document.elementFromPoint(x, y);
        const fake = {
          clientX: x,
          clientY: y,
          target: el,
          preventDefault() {},
        };
        document.dispatchEvent(new Event("mousemove")); // keeps iOS from freezing caret
        // call the same handlers by directly running the bodies:
        // we can simulate by triggering the 'dragover' path:
        // reusing your code: just call the function we already attached
        // -> we can't call anonymous listeners, so inline the minimal core here:

        const row = el?.closest?.("li[data-type]");
        if (row && row !== dragEl && !row.contains(dragEl)) {
          let slot = slotFromEvent(fake, row);
          if (isRootLi(row)) slot = "into";

          const summary =
            row.querySelector(":scope > details > summary") ||
            row.querySelector(":scope > summary") ||
            row;
          const r = summary.getBoundingClientRect();

          if (slot === "before") {
            // show line above row
            // setGuideAt / clearInto are in closure
            clearInto();
            setGuideAt(r.top - 2, r.left, r.width);
          } else if (slot === "after") {
            clearInto();
            setGuideAt(r.bottom - 2, r.left, r.width);
          } else {
            clearGuide();
            if (!isRootLi(row)) {
              if (intoRow !== row) {
                clearInto();
                row.classList.add("into-target");
                intoRow = row;
              }
            } else {
              const topUl = document.querySelector(".tree ul[role=tree]");
              const wr = topUl.getBoundingClientRect();
              const firstReal = [...topUl.children].find(
                (n) => n.matches("li[data-type]") && !isRootLi(n),
              );
              const yTop = firstReal
                ? firstReal.getBoundingClientRect().top - 2
                : wr.top + 6;
              setGuideAt(yTop, wr.left, wr.width);
            }
          }
          return;
        }

        const ul = el?.closest?.("ul");
        if (ul) {
          const rows = containerRows(ul);
          const wr = ul.getBoundingClientRect();
          let insertAt = rows.length;
          for (let i = 0; i < rows.length; i += 1) {
            const rr = rows[i].getBoundingClientRect();
            if (y < rr.top + rr.height / 2) {
              insertAt = i;
              break;
            }
          }
          const lineY =
            rows.length === 0
              ? wr.top + 6
              : insertAt === 0
              ? rows[0].getBoundingClientRect().top - 2
              : insertAt >= rows.length
              ? rows[rows.length - 1].getBoundingClientRect().bottom - 2
              : rows[insertAt].getBoundingClientRect().top - 2;

          clearInto();
          setGuideAt(lineY, wr.left, wr.width);
        }
      }

      function handleTouchDrop(x, y) {
        const el = document.elementFromPoint(x, y);
        const row = el?.closest?.("li[data-type]");
        const ulFrom = (node) =>
          node
            ?.closest?.("li[data-type]")
            ?.querySelector?.(":scope > details > ul") ||
          node
            ?.closest?.("li[data-type]")
            ?.querySelector?.(
              `ul[data-box-id='${node.closest("li[data-type]")?.dataset.id}']`,
            ) ||
          document.querySelector(".tree ul[role=tree]");

        let targetUl, parentLi, insertAt, insertRef;

        if (row && row !== dragEl && !row.contains(dragEl)) {
          let slot = slotFromEvent({ clientY: y }, row);
          if (isRootLi(row)) slot = "into";

          if (slot === "before" || slot === "after") {
            parentLi =
              row.parentElement.closest("li[data-type]") ||
              document.querySelector(".tree li[data-type='root']");
            targetUl =
              parentLi.dataset?.type === "root"
                ? document.querySelector(".tree ul[role=tree]")
                : ulFrom(parentLi);
            const rows = containerRows(targetUl);
            const idx = rows.indexOf(row);
            insertAt =
              slot === "before"
                ? Math.max(0, idx)
                : Math.min(rows.length, idx + 1);
            insertRef = rows[insertAt] || null;
          } else {
            parentLi = row;
            targetUl = ulFrom(parentLi);
            const rows = containerRows(targetUl);
            insertAt = 0;
            insertRef = rows[0] || null;
          }
        } else {
          targetUl =
            el?.closest?.("ul") ||
            document.querySelector(".tree ul[role=tree]");
          parentLi =
            targetUl.closest("li[data-type]") ||
            document.querySelector(".tree li[data-type='root']");
          const rows = containerRows(targetUl);
          insertAt = rows.length;
          for (let i = 0; i < rows.length; i += 1) {
            const rr = rows[i].getBoundingClientRect();
            if (y < rr.top + rr.height / 2) {
              insertAt = i;
              break;
            }
          }
          insertRef = rows[insertAt] || null;
        }

        if (parentLi && parentLi.contains(dragEl)) return;

        const prevParentLi =
          dragEl.parentElement.closest("li[data-type]") ||
          document.querySelector(".tree li[data-type='root']");

        safeInsert(targetUl, dragEl, insertRef, insertAt);
        updateBoxType(prevParentLi);
        updateBoxType(parentLi);

        const movedId = dragEl.dataset.id;
        const newParentId = isRootLi(parentLi) ? "" : parentLi.dataset.id || "";
        const child_ids = buildChildIds(targetUl);

        fetch(editBoxForm.action, {
          method: "PATCH",
          headers: {
            accept: "application/json",
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            box_id: newParentId,
            parent_id: newParentId,
            child_ids,
            moved_id: movedId,
          }),
        })
          .then((r) =>
            r.ok ? r.json() : Promise.reject(new Error("Update failed")),
          )
          .then((data) => {
            upsertBox(data.data);
          })
          .catch((err) => {
            showFlash(err.message || "Move failed");
          })
          .finally(() => {
            clearInto();
            clearGuide();
          });
      }

      document.addEventListener(
        "touchstart",
        (e) => {
          const t = pt(e);
          if (!t) return;
          const li = e.target.closest?.("li[data-type]");
          if (!li || isRootLi(li)) return;
          startEl = li;
          pressTimer = setTimeout(() => {
            // begin pseudo-drag
            dragEl = startEl;
            dragEl.classList.add("dragging");
            touchDrag = true;
            handleTouchOver(t.clientX, t.clientY);
          }, LONG_PRESS_MS);
        },
        { passive: true },
      );

      document.addEventListener(
        "touchmove",
        (e) => {
          const t = pt(e);
          if (!t) return;
          if (pressTimer) {
            clearTimeout(pressTimer);
            pressTimer = null;
          }
          if (!touchDrag) return;
          e.preventDefault();
          handleTouchOver(t.clientX, t.clientY);
        },
        { passive: false },
      );

      document.addEventListener("touchend", (e) => {
        const t = pt(e);
        if (pressTimer) {
          clearTimeout(pressTimer);
          pressTimer = null;
        }
        if (!touchDrag) return;
        e.preventDefault();
        handleTouchDrop(t.clientX, t.clientY);
        dragEl?.classList.remove("dragging");
        dragEl = null;
        touchDrag = false;
      });

      document.addEventListener("touchcancel", () => {
        if (pressTimer) {
          clearTimeout(pressTimer);
          pressTimer = null;
        }
        touchDrag = false;
        clearInto();
        clearGuide();
        dragEl?.classList.remove("dragging");
        dragEl = null;
      });
    })();
  }

  document.addEventListener("submit", (evt) => {
    const form = evt.target;
    if (!form) return;

    evt.preventDefault();
    const formData = new FormData(form);
    fetch(form.action, {
      method: form.method,
      body: formData,
      headers: {
        accept: "application/json",
      },
    })
      .then((response) => {
        if (response.ok) {
          return response.json();
        } else {
          // TODO: Controller should render JSON errors
          throw new Error("Invalid box (ensure name is entered)");
        }
      })
      .then((data) => {
        const box = data.data;
        upsertBox(box);
        form.reset();
        hideModal("edit-modal");
      })
      .catch((error) => {
        showFlash(error.message);
        // console.error("There was a problem with the fetch operation:", error);
      });
  });

  document.addEventListener("click", function (evt) {
    const li = evt.target.closest("li[data-type]");
    if (li) {
      selectBox(li);
    }

    const btn = evt.target.closest(".delete-button");
    if (btn) {
      if (
        !confirm(
          "Are you sure you want to delete this box and ALL of it's contents? This is PERMANENT and CANNOT be undone.",
        )
      ) {
        return;
      }
      evt.preventDefault();
      fetch(editBoxForm.action, {
        method: "DELETE",
        headers: {
          accept: "application/json",
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ box_id: editBoxForm.box_id.value }),
      })
        .then((response) => {
          if (response.ok) {
            return response.json();
          } else {
            throw new Error("Network response was not ok");
          }
        })
        .then((data) => {
          const box = data.data;
          upsertBox(box);
          editBoxForm.reset();
          hideModal("edit-modal");
        })
        .catch((error) => {
          console.error("There was a problem with the fetch operation:", error);
        });
    }
  });

  function attachDetailsToggleListeners() {
    const detailsElements = document.querySelectorAll(
      ".inventory-wrapper details:not(.loaded):not(.pending-load)",
    );

    detailsElements.forEach((details) => {
      const wrapper = details.closest("li[data-id]");
      let loading = details.classList.contains("loading");
      let needsLoad =
        !loading && !!details.querySelector(":scope > ul > li.post-load-box");
      details.classList.add(needsLoad ? "pending-load" : "loaded");

      details.addEventListener("toggle", () => {
        if (!details.open) return;

        if (loading) {
          return;
        } else if (needsLoad) {
          loading = true;
          details.classList.add("loading");
          fetch(`/inventory/boxes/${wrapper.dataset.id}`)
            .then((response) => response.text())
            .then((html) => {
              const ul = details.querySelector(":scope > ul");
              const tempDiv = document.createElement("div");
              tempDiv.innerHTML = html;
              const newUl = tempDiv.querySelector(":scope > li > details > ul");
              if (newUl) {
                ul.replaceWith(newUl);
              } else {
                ul.innerHTML = html;
              }
              details.classList.remove("pending-load");
              details.classList.add("loaded");
              needsLoad = false;
              loading = false;
              updateBoxType(wrapper);
              attachDetailsToggleListeners();
              ensureDraggableRoots();
            })
            .catch((error) => {
              console.error("Error loading box contents:", error);
              details.classList.remove("pending-load");
              details.classList.add("load-error");
            });
        }
      });
    });
  }
  attachDetailsToggleListeners();
  attachDragAndDrop();

  function selectBox(li) {
    document.querySelectorAll("li[data-type].selected").forEach((el) => {
      el.classList.remove("selected");
    });

    li.classList.add("selected");
    inventoryForm.querySelector("#new_box_parent_id").value =
      li.dataset.id || "";
    searchField.focus();
    searchWrapper.querySelector("code.hierarchy").innerText =
      li.dataset.hierarchy || "";

    if (li.dataset.type === "root") {
      editModalBtn.disabled = true;
    } else {
      editModalBtn.disabled = false;
      console.log(editModal);
      console.log(editBoxForm);
      const details = li.querySelector(":scope > details > summary");
      const boxName = details.querySelector(".item-name").innerText;
      const boxNotes = details.querySelector(".item-notes").innerText;
      const boxDescription =
        details.querySelector(".item-description").innerText;

      editBoxForm.querySelector("input[name='box_id']").value = li.dataset.id;
      // editBoxForm.querySelector("input[name='parent_id']").value =
      //   li.dataset.parent_id;
      editBoxForm.querySelector("input[name='name']").value = boxName;
      editBoxForm.querySelector("input[name='notes']").value = boxNotes;
      editBoxForm.querySelector("textarea[name='description']").value =
        boxDescription;
    }
  }
};

document.addEventListener("DOMContentLoaded", () => {
  if (document.querySelector(".ctr-inventory_management.act-show")) {
    loadInventory();
  }
});
