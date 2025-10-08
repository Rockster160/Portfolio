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
    let lastTarget = null;
    let lastSlot = null;
    let guide = null;

    function clearGuides() {
      lastTarget?.classList.remove("drop-target");
      lastTarget = null;
      lastSlot = null;
      guide?.remove();
      guide = null;
    }

    function ensureGuide() {
      if (guide) return guide;
      guide = document.createElement("div");
      guide.className = "drop-guide";
      document.body.appendChild(guide);
      return guide;
    }

    function placeGuide(slot, targetLi) {
      const g = ensureGuide();
      const summary =
        targetLi.querySelector(":scope > details > summary") ||
        targetLi.querySelector(":scope > summary") ||
        targetLi;
      const r = summary.getBoundingClientRect();

      // Root is always INTO, but keep a subtle underline for feedback
      if (targetLi.dataset.type === "root") slot = "into";

      if (slot === "before") {
        g.style.left = `${r.left}px`;
        g.style.width = `${r.width}px`;
        g.style.top = `${r.top - 2}px`;
      } else if (slot === "after") {
        g.style.left = `${r.left}px`;
        g.style.width = `${r.width}px`;
        g.style.top = `${r.bottom - 2}px`;
      } else {
        g.style.left = `${r.left + 12}px`;
        g.style.width = `${r.width - 24}px`;
        g.style.top = `${r.top + r.height - 6}px`;
      }
    }

    document.addEventListener("dragstart", (evt) => {
      const li = evt.target.closest("li[data-type]");
      if (!li || li.dataset.type === "root") return;
      dragEl = li;
      li.classList.add("dragging");
      evt.dataTransfer.setData("text/plain", li.dataset.id || "");
      evt.dataTransfer.effectAllowed = "move";
    });

    document.addEventListener("dragend", () => {
      dragEl?.classList.remove("dragging");
      dragEl = null;
      clearGuides();
    });

    document.addEventListener("dragover", (evt) => {
      const targetLi = evt.target.closest("li[data-type]");
      if (!dragEl || !targetLi || !canDrop(dragEl, targetLi)) return;
      evt.preventDefault();

      let slot = slotFromEvent(evt, targetLi);
      if (targetLi.dataset.type === "root") slot = "into";

      if (lastTarget !== targetLi || lastSlot !== slot) {
        clearGuides();
        targetLi.classList.add("drop-target");
        placeGuide(slot, targetLi);
        lastTarget = targetLi;
        lastSlot = slot;
      }

      evt.dataTransfer.dropEffect = "move";
    });

    document.addEventListener("dragleave", (evt) => {
      const leaving = evt.target.closest("li[data-type]");
      if (leaving && leaving === lastTarget) clearGuides();
    });

    document.addEventListener("drop", (evt) => {
      const targetLi = evt.target.closest("li[data-type]");
      if (!dragEl || !targetLi || !canDrop(dragEl, targetLi)) return;
      evt.preventDefault();

      let slot = slotFromEvent(evt, targetLi);
      if (targetLi.dataset.type === "root") slot = "into";

      let newParentLi;
      let insertRef = null;

      if (slot === "into") {
        newParentLi = targetLi;
      } else {
        newParentLi =
          targetLi.dataset.type === "root"
            ? targetLi
            : targetLi.closest("li[data-type]");
        const containerUl = targetUlFor(newParentLi);
        if (!containerUl) return;

        if (slot === "before") {
          insertRef = targetLi;
        } else {
          const sibs = [...containerUl.children]
            .filter((n) => n.matches("li[data-type]"))
            // when parent is root, ignore the root row
            .filter(
              (n) =>
                newParentLi.dataset.type !== "root" ||
                n.dataset.type !== "root",
            );
          const idx = sibs.indexOf(targetLi);
          insertRef = sibs[idx + 1] || null;
        }
      }

      const oldParentLi =
        dragEl.parentElement.closest("li[data-type]") ||
        tree.querySelector("li[data-type='root']");

      const parentUl = targetUlFor(newParentLi);
      if (!parentUl) return;

      if (insertRef) parentUl.insertBefore(dragEl, insertRef);
      else {
        if (newParentLi.dataset.type === "root") {
          // append to end of top-level, not before the root sentinel
          parentUl.appendChild(dragEl);
        } else {
          parentUl.appendChild(dragEl);
        }
      }

      updateBoxType(oldParentLi);
      updateBoxType(newParentLi);

      const insert_at = siblingIndex(dragEl);
      const draggedId = dragEl.dataset.id;
      const parentId =
        newParentLi.dataset.type === "root" ? "" : newParentLi.dataset.id || "";

      fetch(editBoxForm.action, {
        method: "PATCH",
        headers: {
          accept: "application/json",
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          box_id: draggedId,
          parent_id: parentId,
          insert_at,
        }),
      })
        .then((r) =>
          r.ok ? r.json() : Promise.reject(new Error("Update failed")),
        )
        .then((data) => {
          const li = tree.querySelector(`li[data-id='${draggedId}']`);
          const oldH = li?.dataset.hierarchy || "";
          upsertBox(data.data);
          const newLi = tree.querySelector(`li[data-id='${draggedId}']`);
          if (li && newLi) {
            propagateHierarchyChange(
              newLi,
              oldH,
              newLi.dataset.hierarchy || "",
            );
          }
        })
        .catch((err) => {
          showFlash(err.message || "Move failed");
        })
        .finally(() => {
          clearGuides();
          dragEl?.classList.remove("dragging");
          dragEl = null;
        });
    });
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
