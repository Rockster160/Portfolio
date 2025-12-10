import { showModal, hideModal, openedModal } from "./modal.js";
import { showFlash } from "./flash.js";

const loadInventory = () => {
  const tree = document.querySelector(".tree");
  const searchWrapper = document.querySelector(".inventory-nav");
  const inventoryForm = document.querySelector(".new-item-form");
  const newBoxField = inventoryForm.querySelector("#new_box_name");
  const editModalBtn = document.querySelector(".edit-button");
  const editModal = document.querySelector("#edit-modal");
  const editBoxForm = document.querySelector("#editBoxForm");

  const searchModal = document.querySelector("#search-modal");
  const searchModalForm = searchModal?.querySelector("form");
  const searchModalField = searchModal?.querySelector("input#name");
  const searchResults = searchModal?.querySelector(".search-results");
  const breadcrumbWrapper = document.querySelector(".search-breadcrumbs");

  function upsertBox(box) {
    const existingLi = tree.querySelector(`li[data-id='${box.id}']`);
    if (existingLi) {
      if (box.deleted) {
        const parentLi = existingLi.closest(
          `li[data-id='${existingLi.dataset.parentKey}']`,
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
      const oldParentKey = existingLi.dataset.parentKey || "";

      if (!isRootLi(existingLi)) {
        existingLi.dataset.type = box.empty ? "item" : "box";
      }
      existingLi.dataset.sortOrder = box.sort_order;
      existingLi.querySelector(".item-name").innerText = box.name;
      existingLi.querySelector(".item-notes").innerText = box.notes || "";
      existingLi.querySelector(".item-description").innerText =
        box.description || "";
      existingLi.dataset.hierarchy = box.hierarchy;
      existingLi.dataset.parentKey = box.parent_key || "";

      if (oldParentKey !== (box.parent_key || "")) {
        const oldParent =
          tree.querySelector(`li[data-id='${oldParentKey}']`) || null;
        const newParent =
          tree.querySelector(`li[data-id='${box.parent_key}']`) ||
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
      li.dataset.parentKey = box.parent_key || "";
      li.querySelector(".item-name").innerText = box.name;
      li.querySelector(".item-notes").innerText = box.notes || "";
      li.querySelector(".item-description").innerText = box.description || "";
      li.querySelector("ul[data-box-id='']").dataset.boxId = box.id;
      li.dataset.type = box.empty ? "item" : "box";

      const parentLi = tree.querySelector(`li[data-id='${box.parent_key}']`);
      const ul = parentLi
        ? parentLi.querySelector(`ul[data-box-id='${box.parent_key}']`)
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
      const codeEl = document.querySelector(".inventory-nav code.hierarchy");
      if (codeEl) codeEl.innerText = selected.dataset.hierarchy || "";
    }
  }

  function buildBreadcrumbs(selectedLi) {
    breadcrumbWrapper.innerHTML = "";

    const container = document.createElement("div");
    container.className = "breadcrumbs";

    const ul = document.createElement("ul");
    container.appendChild(ul);

    // Always start with "Everything"
    ul.appendChild(
      makeBreadcrumb("Everything", "", !selectedLi && pageHierarchy === ""),
    );

    // Choose hierarchy source:
    // 1. selected row if you're selecting inside the tree
    // 2. pageHierarchy if you're inside a box page
    let parts = [];
    let ids = [];

    if (selectedLi && selectedLi.dataset.hierarchy) {
      parts = selectedLi.dataset.hierarchy.split(" > ");
      ids = ancestorIdChain(selectedLi);
    } else if (pageHierarchy) {
      parts = pageHierarchyParts;
      ids = pageHierarchyIds;
    }

    parts.forEach((name, idx) => {
      ul.appendChild(makeBreadcrumb(name, ids[idx], idx === parts.length - 1));
    });

    breadcrumbWrapper.appendChild(container);
  }

  function makeBreadcrumb(label, id, selected) {
    const li = document.createElement("li");
    li.className = "crumb";

    const input = document.createElement("input");
    input.type = "radio";
    input.name = "crumb";
    input.value = id;
    if (selected) input.checked = true;

    const span = document.createElement("span");
    span.className = "crumb-label";
    span.innerText = label;

    li.appendChild(input);
    li.appendChild(span);

    // Make *entire pill* clickable
    li.addEventListener("click", () => {
      input.checked = true;
      breadcrumbWrapper.dispatchEvent(new Event("change"));
    });

    return li;
  }

  function ancestorIdChain(li) {
    const chain = [];
    let cur = li;
    while (cur && !isRootLi(cur)) {
      chain.unshift(cur.dataset.id);

      debugger;
      cur = tree.querySelector(`li[data-id='${cur.dataset.parentKey}']`);
    }
    return chain;
  }

  let searchTimer;

  function triggerSearch() {
    clearTimeout(searchTimer);
    searchTimer = setTimeout(runSearch, 300);
  }

  function runSearch() {
    const q = searchModalField.value.trim();
    const parentKey =
      breadcrumbWrapper.querySelector("input[name='crumb']:checked")?.value ||
      "";

    if (!q) {
      searchResults.innerHTML = "";
      return;
    }

    fetch(
      `${searchModalForm.action}?q=${encodeURIComponent(
        q,
      )}&within=${parentKey}`,
      {
        headers: { accept: "application/json" },
      },
    )
      .then((r) => (r.ok ? r.json() : Promise.reject()))
      .then((data) => renderSearchResults(data))
      .catch(() => showFlash("Search failed"));
  }

  function renderSearchResults(data) {
    searchResults.innerHTML = "";

    const template = searchModal.querySelector("#box-search-result-template");
    if (!template) return;

    data.data.forEach((box) => {
      const clone = template.content.cloneNode(true);
      const li = clone.querySelector(".search-result");

      li.addEventListener("click", () => {
        window.location.href = `/b/${box.param_key}`;
      });

      li.dataset.id = box.id;
      li.dataset.type = box.empty ? "item" : "box";

      clone.querySelector(".item-hierarchy").innerText = box.hierarchy || "";
      clone.querySelector(".item-name").innerText = box.name;
      clone.querySelector(".item-description").innerText =
        box.description || "";

      const tagEl = clone.querySelector(".item-tags");
      tagEl.innerHTML = "";

      if (Array.isArray(box.tags)) {
        box.tags.forEach((tag) => {
          const span = document.createElement("span");
          span.className = "tag";
          span.innerText = tag;
          tagEl.appendChild(span);
        });
      }

      searchResults.appendChild(clone);
    });
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

  function targetUlFor(li) {
    if (li.dataset.type === "root") {
      return document.querySelector(".tree ul[role=tree]");
    }
    return (
      li.querySelector(`:scope > details > ul`) ||
      li.querySelector(`ul[data-box-id='${li.dataset.id}']`)
    );
  }

  function buildChildIds(containerUl) {
    return containerRows(containerUl)
      .map((n) => parseInt(n.dataset.id, 10))
      .filter((n) => Number.isFinite(n));
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

      // Prevent dropping INTO your own subtree (reordering in same parent is allowed)
      if (parentLi && dragEl.contains(parentLi)) return;

      const prevParentLi =
        dragEl.parentElement.closest("li[data-type]") || rootLi();

      // Optimistic move
      safeInsert(targetUl, dragEl, insertRef, insertAt);

      updateBoxType(prevParentLi);
      updateBoxType(parentLi);

      const movedId = dragEl.dataset.id;
      const newParentKey = isRootLi(parentLi) ? "" : parentLi.dataset.id || "";
      const child_ids = buildChildIds(targetUl);

      fetch(editBoxForm.action, {
        method: "PATCH",
        headers: {
          accept: "application/json",
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          box_id: movedId,
          parent_key: newParentKey,
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
  }

  document.addEventListener("keypress", (evt) => {
    if (evt.target.matches("input, textarea")) return;
    if (openedModal()) return;

    newBoxField.focus();
  });

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

  // If we are on a box page, read its hierarchy for default search scope
  const pageHierarchy =
    document.querySelector(".inventory-nav code.hierarchy")?.innerText.trim() ||
    "";
  const pageHierarchyParts = pageHierarchy ? pageHierarchy.split(" > ") : [];
  const pageHierarchyIds = [];

  if (pageHierarchy && tree) {
    // Convert “A > B > C” into parent-key chain
    let cur = tree.querySelector(`li[data-hierarchy='${pageHierarchy}']`);
    while (cur && !isRootLi(cur)) {
      pageHierarchyIds.unshift(cur.dataset.id);
      cur = tree.querySelector(`li[data-id='${cur.dataset.parentKey}']`);
    }
  }

  searchModal.addEventListener("modal:show", function () {
    const selected = document.querySelector("li[data-type].selected");
    buildBreadcrumbs(selected);
    searchModal.querySelector(".modal-content").prepend(breadcrumbWrapper);
    showModal("search-modal");
    setTimeout(() => searchModalField.focus(), 50);
  });

  searchModalField?.addEventListener("input", triggerSearch);

  breadcrumbWrapper.addEventListener("change", () => {
    triggerSearch();
  });

  document.addEventListener("click", function (evt) {
    const cog = evt.target.closest(".edit-box");
    if (cog) {
      selectBox(cog.closest("li[data-type]"));
      showModal("edit-modal");
      return;
    }

    const li = evt.target.closest("li[data-type]");
    if (li) {
      return selectBox(li);
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

      return;
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
    inventoryForm.querySelector("#new_box_parent_key").value =
      li.dataset.id || "";
    searchWrapper.querySelector("code.hierarchy").innerText =
      li.dataset.hierarchy || "";

    if (li.dataset.type === "root") {
      editModalBtn.disabled = true;
    } else {
      editModalBtn.disabled = false;
      const details = li.querySelector(":scope > details > summary");
      const boxName = details.querySelector(".item-name").innerText;
      const boxNotes = details.querySelector(".item-notes").innerText;
      const boxDescription =
        details.querySelector(".item-description").innerText;

      const copyUrl = editBoxForm.querySelector(".copy-url input.url");
      copyUrl.value = `${copyUrl.placeholder.replace(":id", li.dataset.key)}`;
      const qrBtn = editBoxForm.querySelector(".copy-url .qr-btn");
      if (qrBtn) {
        qrBtn.href = `${qrBtn.attributes.placeholder.value.replace(
          "%3Abox_id",
          li.dataset.key,
        )}`;
      }
      editBoxForm.querySelector("input[name='box_id']").value = li.dataset.id;
      editBoxForm.querySelector("input[name='name']").value = boxName;
      editBoxForm.querySelector("input[name='notes']").value = boxNotes;
      editBoxForm.querySelector("textarea[name='description']").value =
        boxDescription;
    }
  }
};

document.addEventListener("DOMContentLoaded", () => {
  if (document.querySelector(".ctr-inventory_management")) {
    loadInventory();
  }
});
