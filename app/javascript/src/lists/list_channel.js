import consumer from "./../channels/consumer";

document.addEventListener("DOMContentLoaded", () => {
  const listsRoot = document.querySelector(".ctr-lists.act-show");
  if (!listsRoot) return;

  const listContainer = document.querySelector(".list-container");
  if (!listContainer) return;

  const listId = listContainer.getAttribute("data-list-id");

  function norm(s) {
    return (s || "").toLowerCase().trim().replace(/\s+/g, " ");
  }

  function itemKey(el) {
    const name = norm(el.querySelector(".item-name")?.textContent || "");
    const cat = norm(
      el.querySelector(".list-item-config .category")?.textContent || "",
    );
    return cat + "|" + name;
  }

  function getOrder(el) {
    const raw = el.getAttribute("data-sort-order");
    let v = Number.parseInt(raw || "0", 10) || 0;

    if (el.classList.contains("list-item-container")) {
      const cb = el.querySelector(".list-item-checkbox");
      if (cb && cb.checked) v += 0.1;
    }

    return v;
  }

  function sortBucket(bucket) {
    const items = Array.from(
      bucket.querySelectorAll(":scope > .list-item-container"),
    );
    items.sort((a, b) => getOrder(b) - getOrder(a));
    items.forEach((item) => bucket.appendChild(item));
  }

  function sortTopLevel() {
    const root = document.querySelector(".list-items");
    if (!root) return;

    const kids = Array.from(
      root.querySelectorAll(
        ":scope > .list-item-container, :scope > .list-section-tab",
      ),
    );
    kids.sort((a, b) => getOrder(b) - getOrder(a));
    kids.forEach((kid) => root.appendChild(kid));
  }

  function reorderAll() {
    sortTopLevel();
    document.querySelectorAll(".section-items").forEach((bucket) => {
      sortBucket(bucket);
    });
  }

  function upsertSections(incomingSections) {
    Object.keys(incomingSections).forEach((sid) => {
      const inc = incomingSections[sid];
      const curr = document.querySelector(
        '.list-section-tab[data-section-id="' + sid + '"]',
      );

      if (!curr) {
        const root = document.querySelector(".list-items");
        if (root) root.appendChild(inc);
        return;
      }

      const currBucket = curr.querySelector(":scope > .section-items");
      const incBucket = inc.querySelector(":scope > .section-items");

      curr.setAttribute(
        "data-sort-order",
        inc.getAttribute("data-sort-order") || "0",
      );

      const incName = inc.querySelector(".section-header .section-name");
      if (incName) {
        const currName = curr.querySelector(".section-header .section-name");
        if (currName) currName.textContent = incName.textContent;
      }

      const incColor = inc.getAttribute("data-color");
      if (incColor) curr.setAttribute("data-color", incColor);

      if (!currBucket && incBucket) {
        const bucket = document.createElement("div");
        bucket.className = "section-items";
        curr.appendChild(bucket);
      }
    });
  }

  function parseIncoming(html) {
    const wrap = document.createElement("div");
    wrap.innerHTML = html;

    let root = wrap.querySelector(".list-items");
    if (!root) root = wrap;

    const incomingItems = {};
    const itemNodes = Array.from(root.querySelectorAll(".list-item-container"));
    if (root.classList.contains("list-item-container")) {
      itemNodes.unshift(root);
    }
    itemNodes.forEach((el) => {
      const id = String(el.dataset.itemId || "");
      if (id) incomingItems[id] = el;
    });

    const incomingSections = {};
    const sectionNodes = Array.from(root.querySelectorAll(".list-section-tab"));
    if (root.classList.contains("list-section-tab")) {
      sectionNodes.unshift(root);
    }
    sectionNodes.forEach((el) => {
      const id = String(el.dataset.sectionId || "");
      if (id) incomingSections[id] = el;
    });

    function targetFor(incomingItem) {
      const rootList = document.querySelector(".list-items");
      if (!rootList) return document.body;

      const section = incomingItem.closest(".list-section-tab");
      const sid = section?.dataset.sectionId;
      if (!sid) return rootList;

      const tab = document.querySelector(
        '.list-section-tab[data-section-id="' + sid + '"]',
      );
      if (!tab) return rootList;

      const bucket = tab.querySelector(":scope > .section-items");
      return bucket || rootList;
    }

    return { root, incomingItems, incomingSections, targetFor };
  }

  function ensureParent(el, targetBucket) {
    if (!targetBucket) return;
    if (el.parentElement !== targetBucket) {
      targetBucket.appendChild(el);
    }
  }

  function csrfToken() {
    const meta = document.querySelector("meta[name=csrf-token]");
    return meta?.getAttribute("content") || "";
  }

  function applyWsUpdate(data) {
    if (!data || typeof data.list_html !== "string") return;

    const {
      root: incRoot,
      incomingItems,
      incomingSections,
      targetFor,
    } = parseIncoming(data.list_html);

    if (!incRoot) return;

    const incIds = Object.keys(incomingItems);

    upsertSections(incomingSections);

    // resolve placeholders by name/category first
    document.querySelectorAll(".item-placeholder").forEach((ph) => {
      const key = itemKey(ph);

      const existing = Array.from(
        document.querySelectorAll(".list-item-container"),
      )
        .filter((el) => !el.classList.contains("item-placeholder"))
        .find((el) => itemKey(el) === key);

      if (existing) {
        ph.remove();
        return;
      }

      let match = null;
      Object.values(incomingItems).some((inc) => {
        if (itemKey(inc) === key) {
          match = inc;
          return true;
        }
        return false;
      });

      if (match) {
        const targetBucket = targetFor(match);
        ensureParent(match, targetBucket);
        ph.replaceWith(match);
      } else if (!ph.classList.contains("item-queued")) {
        ph.remove();
      }
    });

    Object.keys(incomingItems).forEach((id) => {
      const inc = incomingItems[id];
      if (!inc) return;

      const targetBucket = targetFor(inc);
      let curr = document.querySelector(
        '.list-item-container[data-item-id="' + id + '"]',
      );

      if (!curr) {
        const key = itemKey(inc);
        curr =
          Array.from(document.querySelectorAll(".list-item-container"))
            .filter((el) => !el.classList.contains("item-placeholder"))
            .find((el) => itemKey(el) === key) || null;
      }

      if (!curr) {
        ensureParent(inc, targetBucket);
        return;
      }

      const cfg = curr.querySelector(".list-item-config");

      ["important", "locked", "recurring"].forEach((cls) => {
        const has = !!inc.querySelector(".list-item-config ." + cls);
        if (!cfg) return;

        if (has) {
          if (!cfg.querySelector("." + cls)) {
            const div = document.createElement("div");
            div.className = cls;
            cfg.appendChild(div);
          }
        } else {
          cfg.querySelectorAll("." + cls).forEach((el) => el.remove());
        }
      });

      const incCat = inc.querySelector(".list-item-config .category");
      if (incCat && cfg) {
        const currCat = cfg.querySelector(".category");
        if (currCat) currCat.textContent = incCat.textContent;
      }

      curr.setAttribute(
        "data-sort-order",
        inc.getAttribute("data-sort-order") || "0",
      );

      const incName = inc.querySelector(".item-name");
      const currName = curr.querySelector(".item-name");
      if (incName && currName) currName.innerHTML = incName.innerHTML;

      const incLocked = inc.querySelector(".list-item-config .locked");
      if (!incLocked) {
        const incCb = inc.querySelector(".list-item-checkbox");
        const currCb = curr.querySelector(".list-item-checkbox");
        if (incCb && currCb) currCb.checked = incCb.checked;
      }

      ensureParent(curr, targetBucket);
    });

    // auto-check items that disappeared from the payload
    document.querySelectorAll(".list-item-container").forEach((el) => {
      const locked = el.querySelector(".list-item-config .locked");
      if (locked) return;

      const id = el.dataset.itemId;
      if (!id) return;
      if (incIds.includes(String(id))) return;

      const cb = el.querySelector("input[type=checkbox]");
      if (cb) cb.checked = true;
    });

    if (typeof clearRemovedItems === "function") {
      clearRemovedItems();
    }

    if (typeof setImportantItems === "function") {
      setImportantItems();
    }

    if (!window.__listReorderPending) reorderAll();

    // let drag/drop bindings reattach without duplicating state
    document.dispatchEvent(new Event("lists:rebind"));
  }

  window.listWS = consumer.subscriptions.create(
    {
      channel: "ListHtmlChannel",
      channel_id: "list_" + listId,
    },
    {
      connected() {
        window.__listWsConnected = true;
        const url = document
          .querySelector(".list-items")
          ?.getAttribute("data-update-url");

        if (!url) return;

        fetch(url, {
          method: "POST",
          headers: {
            "X-CSRF-Token": csrfToken(),
            "X-Requested-With": "XMLHttpRequest",
            Accept: "text/javascript, application/json, text/html, */*",
            "Content-Type": "application/json",
          },
          body: "{}",
        }).then((resp) => {
          if (!resp.ok) return;
          const err = document.querySelector(".list-error");
          if (err) err.classList.add("hidden");
          document.dispatchEvent(new Event("lists:process-queue"));
        });
      },

      disconnected() {
        window.__listWsConnected = false;
        const err = document.querySelector(".list-error");
        if (err) err.classList.remove("hidden");
      },

      received(data) {
        if (!data || typeof data.list_html !== "string") return;

        // Defer DOM updates while a drag is in progress to avoid
        // corrupting jQuery UI Sortable state (which causes items
        // to freeze with position:absolute styling).
        if (window.__listDragging) {
          window.__pendingWsData = data;
          return;
        }

        applyWsUpdate(data);
      },
    },
  );

  // Replay deferred WebSocket data after a drag completes
  document.addEventListener("lists:ws-replay", function (e) {
    applyWsUpdate(e.detail);
  });
});
