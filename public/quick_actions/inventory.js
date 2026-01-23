import { showModal, hideModal, openedModal } from "./modal.js";
import { showFlash } from "./flash.js";
// ============================================================================
// History Management (Undo/Redo)
// ============================================================================
class History {
  static states = [];
  static savedIdx = 0;
  static currentIdx = 0;
  static maxStates = 50;

  static deepEqual(dict1, dict2) {
    return JSON.stringify(dict1) === JSON.stringify(dict2);
  }

  static add(newState) {
    if (this.states.length > 0) {
      const last = this.states[this.states.length - 1];
      if (this.deepEqual(last, newState)) {
        return false;
      }
    }
    this.states = this.states
      .slice(0, this.maxStates - 1)
      .slice(0, this.currentIdx + 1);
    this.states.push(newState);
    this.currentIdx = this.states.length - 1;
    return true;
  }

  static getState() {
    return this.states[this.currentIdx];
  }

  static undo() {
    if (this.currentIdx > 0) {
      this.currentIdx--;
    }
    return this.getState();
  }

  static redo() {
    if (this.currentIdx < this.states.length - 1) {
      this.currentIdx++;
    }
    return this.getState();
  }

  static canUndo() {
    return this.currentIdx > 0;
  }

  static canRedo() {
    return this.currentIdx < this.states.length - 1;
  }
}

// ============================================================================
// Operation Queue for Async Processing
// ============================================================================
class OperationQueue {
  queue = [];
  processing = false;
  pendingItems = new Map(); // tempId -> { element, operation }
  pendingRetries = new Map(); // tempId -> { timeoutId, operation }
  retryDelays = [1000, 2000, 5000]; // Exponential backoff for transient errors
  isOnline = true; // Track connection state

  constructor(inventory) {
    this.inventory = inventory;
    this.createPendingIndicator();
  }

  setOnline(online) {
    const wasOffline = !this.isOnline;
    this.isOnline = online;
    this.updatePendingIndicator();

    // If we just came back online, resume processing immediately
    if (online && wasOffline) {
      // Cancel any pending retry timeouts and add operations back to queue
      for (const [tempId, { timeoutId, operation }] of this.pendingRetries) {
        clearTimeout(timeoutId);
        operation.retryCount = 0;
        this.queue.push(operation);
      }
      this.pendingRetries.clear();

      // Reset retry counts for already-queued operations
      this.queue.forEach((op) => (op.retryCount = 0));

      if (this.queue.length > 0) {
        this.process();
      }
    }
  }

  createPendingIndicator() {
    if (document.getElementById("pending-indicator")) return;
    const indicator = document.createElement("div");
    indicator.id = "pending-indicator";
    indicator.className = "pending-indicator hidden";
    indicator.innerHTML =
      '<span class="pending-dot"></span><span class="pending-text">Syncing...</span>';
    document.body.appendChild(indicator);
  }

  updatePendingIndicator() {
    const indicator = document.getElementById("pending-indicator");
    if (!indicator) return;

    const totalPending =
      this.pendingItems.size + this.queue.length + this.pendingRetries.size;
    const hasPending = totalPending > 0;
    indicator.classList.toggle("hidden", !hasPending);

    if (hasPending) {
      if (!this.isOnline) {
        indicator.querySelector(".pending-text").textContent =
          totalPending === 1
            ? "Offline - 1 change pending..."
            : `Offline - ${totalPending} changes pending...`;
        indicator.classList.add("offline");
      } else {
        indicator.querySelector(".pending-text").textContent =
          totalPending === 1
            ? "Syncing 1 change..."
            : `Syncing ${totalPending} changes...`;
        indicator.classList.remove("offline");
      }
    } else {
      indicator.classList.remove("offline");
    }
  }

  generateTempId() {
    return `temp_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;
  }

  add(operation) {
    // Only generate tempId if not already set (for optimistic updates)
    if (!operation.tempId) {
      operation.tempId = this.generateTempId();
    }
    operation.retryCount = 0;
    this.queue.push(operation);
    this.updatePendingIndicator();
    this.process();
    return operation.tempId;
  }

  async process() {
    if (this.processing || this.queue.length === 0) return;

    // If offline, don't process - queue will resume when we come back online
    if (!this.isOnline) {
      this.updatePendingIndicator();
      return;
    }

    this.processing = true;

    while (this.queue.length > 0) {
      // Check online status before each operation
      if (!this.isOnline) {
        this.processing = false;
        this.updatePendingIndicator();
        return;
      }

      const operation = this.queue.shift();
      try {
        const result = await this.execute(operation);
        this.reconcile(operation.tempId, result);
      } catch (error) {
        // Check if session expired - don't retry, prompt reload
        if (error.message.includes("Session expired")) {
          this.handleSessionExpired();
          this.processing = false;
          return;
        }

        // Check if this is a network error (offline)
        const isNetworkError =
          error.message.includes("Failed to fetch") ||
          error.message.includes("NetworkError") ||
          error.message.includes("Network request failed");

        if (isNetworkError) {
          // Put operation back at front of queue and wait for reconnect
          this.queue.unshift(operation);
          this.setOnline(false);
          this.processing = false;
          return;
        }

        // For other errors, use retry logic
        if (operation.retryCount < this.retryDelays.length) {
          const delay = this.retryDelays[operation.retryCount];
          operation.retryCount++;
          const timeoutId = setTimeout(() => {
            this.pendingRetries.delete(operation.tempId);
            this.queue.unshift(operation);
            this.process();
          }, delay);
          // Track the timeout so we can cancel it if we come back online
          this.pendingRetries.set(operation.tempId, { timeoutId, operation });
        } else {
          this.handleError(operation, error);
        }
      }
    }

    this.processing = false;
  }

  async execute(operation) {
    const { type, url, method, body, getBody } = operation;

    // Support dynamic body computation (for nested items with temp parent keys)
    const requestBody = getBody ? getBody() : body;

    const response = await fetch(url, {
      method: method || "POST",
      headers: {
        accept: "application/json",
        "Content-Type": "application/json",
      },
      body: requestBody ? JSON.stringify(requestBody) : undefined,
      redirect: "manual", // Don't auto-follow redirects
    });

    // Check for redirect (usually means session expired)
    if (response.type === "opaqueredirect" || response.status === 0) {
      throw new Error("Session expired - please refresh the page");
    }

    // Also check if we got redirected to login
    if (response.redirected && response.url.includes("/login")) {
      throw new Error("Session expired - please refresh the page");
    }

    if (!response.ok) {
      throw new Error(`Operation failed: ${response.statusText}`);
    }

    return response.json();
  }

  reconcile(tempId, serverData) {
    const pending = this.pendingItems.get(tempId);
    if (!pending) return;

    const { element, operation } = pending;

    if (element && serverData.data) {
      // Update element with real server data
      element.classList.remove("pending");
      element.dataset.id = serverData.data.id || serverData.data.param_key;
      element.dataset.key = serverData.data.param_key;

      // Update the nested UL's data-box-id
      const ul = element.querySelector("ul[data-box-id]");
      if (ul) {
        ul.dataset.boxId = serverData.data.param_key || serverData.data.id;
      }
    }

    this.pendingItems.delete(tempId);
    this.updatePendingIndicator();

    // Call the operation's success callback if provided
    if (operation.onSuccess) {
      operation.onSuccess(serverData);
    }
  }

  handleError(operation, error) {
    const pending = this.pendingItems.get(operation.tempId);
    if (pending && pending.element) {
      pending.element.classList.remove("pending");
      pending.element.classList.add("error");

      // Add retry button
      const retryBtn = document.createElement("button");
      retryBtn.className = "retry-btn";
      retryBtn.innerHTML = "Retry";
      retryBtn.onclick = (e) => {
        e.stopPropagation();
        pending.element.classList.remove("error");
        pending.element.classList.add("pending");
        retryBtn.remove();
        operation.retryCount = 0;
        this.add(operation);
      };
      pending.element
        .querySelector(":scope > details > summary")
        ?.appendChild(retryBtn);
    }

    this.pendingItems.delete(operation.tempId);
    this.updatePendingIndicator();
    showFlash(error.message || "Operation failed");

    if (operation.onError) {
      operation.onError(error);
    }
  }

  handleSessionExpired() {
    // Clear queue - operations can't succeed without auth
    this.queue = [];

    // Show message and prompt reload
    showFlash("Session expired. Please refresh the page to continue.");

    // Mark all pending items as errors
    for (const [tempId, { element }] of this.pendingItems) {
      if (element) {
        element.classList.remove("pending");
        element.classList.add("error");
      }
    }
    this.pendingItems.clear();
    this.updatePendingIndicator();
  }

  registerPending(tempId, element, operation) {
    this.pendingItems.set(tempId, { element, operation });
    this.updatePendingIndicator();
  }
}

// ============================================================================
// Prefetch Cache for Lazy Loading
// ============================================================================
class PrefetchCache {
  cache = new Map();
  pending = new Set();
  debounceTimer = null;
  queuedIds = new Set();

  async prefetch(boxId) {
    if (this.cache.has(boxId) || this.pending.has(boxId)) return;

    this.queuedIds.add(boxId);

    // Debounce batch prefetch
    clearTimeout(this.debounceTimer);
    this.debounceTimer = setTimeout(() => this.executeBatch(), 100);
  }

  async executeBatch() {
    if (this.queuedIds.size === 0) return;

    const ids = [...this.queuedIds];
    this.queuedIds.clear();

    ids.forEach((id) => this.pending.add(id));

    try {
      const response = await fetch(
        `/inventory/boxes/batch?ids=${ids.join(",")}`,
        {
          headers: { accept: "application/json" },
        },
      );

      if (response.ok) {
        const data = await response.json();
        if (data.data) {
          Object.entries(data.data).forEach(([id, children]) => {
            this.cache.set(id, children);
          });
        }
      }
    } catch (error) {
      console.error("Prefetch failed:", error);
    } finally {
      ids.forEach((id) => this.pending.delete(id));
    }
  }

  get(boxId) {
    return this.cache.get(boxId);
  }

  has(boxId) {
    return this.cache.has(boxId);
  }

  invalidate(boxId) {
    this.cache.delete(boxId);
  }

  clear() {
    this.cache.clear();
  }
}

// ============================================================================
// Recently Viewed Tracker
// ============================================================================
class RecentlyViewed {
  static storageKey = "inventory_recently_viewed";
  static maxItems = 10;

  static get() {
    try {
      return JSON.parse(localStorage.getItem(this.storageKey) || "[]");
    } catch {
      return [];
    }
  }

  static add(box) {
    if (!box || !box.id) return;

    const recent = this.get().filter((item) => item.id !== box.id);
    recent.unshift({
      id: box.id,
      param_key: box.param_key,
      name: box.name,
      hierarchy: box.hierarchy,
      viewedAt: Date.now(),
    });

    localStorage.setItem(
      this.storageKey,
      JSON.stringify(recent.slice(0, this.maxItems)),
    );
  }

  static clear() {
    localStorage.removeItem(this.storageKey);
  }
}

// ============================================================================
// Multi-Select Manager
// ============================================================================
class SelectionManager {
  selected = new Set();
  lastSelected = null;

  constructor(tree) {
    this.tree = tree;
  }

  clear() {
    this.selected.forEach((id) => {
      const li = this.tree.querySelector(`li[data-id='${id}']`);
      if (li) li.classList.remove("bulk-selected", "selected");
    });
    this.selected.clear();
    this.lastSelected = null;
  }

  toggle(li) {
    const id = li.dataset.id;
    if (this.selected.has(id)) {
      this.selected.delete(id);
      li.classList.remove("bulk-selected");
    } else {
      this.selected.add(id);
      li.classList.add("bulk-selected");
    }
    this.lastSelected = li;
  }

  selectRange(li) {
    if (!this.lastSelected) {
      this.toggle(li);
      return;
    }

    const all = [
      ...this.tree.querySelectorAll("li[data-type]:not([data-type='root'])"),
    ];
    const start = all.indexOf(this.lastSelected);
    const end = all.indexOf(li);

    if (start === -1 || end === -1) {
      this.toggle(li);
      return;
    }

    const [from, to] = start < end ? [start, end] : [end, start];
    for (let i = from; i <= to; i++) {
      const el = all[i];
      if (!this.selected.has(el.dataset.id)) {
        this.selected.add(el.dataset.id);
        el.classList.add("bulk-selected");
      }
    }
    this.lastSelected = li;
  }

  selectAllSiblings(li) {
    if (!li) return;
    const parentUl = li.parentElement;
    if (!parentUl) return;

    parentUl
      .querySelectorAll(":scope > li[data-type]:not([data-type='root'])")
      .forEach((sibling) => {
        this.selected.add(sibling.dataset.id);
        sibling.classList.add("bulk-selected");
      });
  }

  getSelectedIds() {
    return [...this.selected];
  }

  hasSelection() {
    return this.selected.size > 0;
  }

  size() {
    return this.selected.size;
  }
}

// ============================================================================
// Main Inventory Module
// ============================================================================
const loadInventory = () => {
  const tree = document.querySelector(".tree");
  const searchWrapper = document.querySelector(".inventory-nav");
  const inventoryForm = document.querySelector(".new-item-form");

  // Defensive checks for required elements
  if (!tree || !inventoryForm) {
    return;
  }

  const newBoxField = inventoryForm.querySelector("#new_box_name");
  const editModalBtn = document.querySelector(".edit-button");
  const editModal = document.querySelector("#edit-modal");
  const editBoxForm = document.querySelector("#editBoxForm");

  const searchModal = document.querySelector("#search-modal");
  const searchModalForm = searchModal?.querySelector("form");
  const searchModalField = searchModal?.querySelector("input#name");
  const searchResults = searchModal?.querySelector(".search-results");
  const breadcrumbWrapper = document.querySelector(".search-breadcrumbs");

  // Initialize managers
  const operationQueue = new OperationQueue(null);
  const prefetchCache = new PrefetchCache();
  const selectionManager = new SelectionManager(tree);

  // Track recently moved items to skip repositioning on our own WebSocket updates
  // Key: param_key, Value: timestamp when moved
  const recentlyMovedItems = new Map();
  const RECENTLY_MOVED_TTL = 5000; // 5 seconds

  function markAsRecentlyMoved(paramKey) {
    if (!paramKey) return;
    recentlyMovedItems.set(paramKey, Date.now());
    // Clean up old entries
    for (const [key, time] of recentlyMovedItems) {
      if (Date.now() - time > RECENTLY_MOVED_TTL) {
        recentlyMovedItems.delete(key);
      }
    }
  }

  function wasRecentlyMoved(paramKey) {
    if (!paramKey) return false;
    const movedTime = recentlyMovedItems.get(paramKey);
    if (!movedTime) return false;
    if (Date.now() - movedTime > RECENTLY_MOVED_TTL) {
      recentlyMovedItems.delete(paramKey);
      return false;
    }
    return true;
  }

  // WebSocket connection
  let ws = null;
  let wsReconnectAttempts = 0;
  const wsMaxReconnectAttempts = 10;

  function connectWebSocket() {
    const protocol = window.location.protocol === "https:" ? "wss:" : "ws:";
    const wsUrl = `${protocol}//${window.location.host}/cable`;

    try {
      ws = new WebSocket(wsUrl);

      ws.onopen = () => {
        wsReconnectAttempts = 0;
        // Notify queue we're back online
        operationQueue.setOnline(true);
        // Subscribe to inventory channel
        ws.send(
          JSON.stringify({
            command: "subscribe",
            identifier: JSON.stringify({ channel: "InventoryChannel" }),
          }),
        );
      };

      ws.onmessage = (event) => {
        try {
          const data = JSON.parse(event.data);
          if (data.type === "ping") return;
          if (data.type === "welcome") return;
          if (data.type === "confirm_subscription") return;

          // STRICT: Only process messages that explicitly come from InventoryChannel
          // Messages without identifier or from other channels are ignored
          if (!data.identifier) return;
          const identifier = JSON.parse(data.identifier);
          if (identifier.channel !== "InventoryChannel") return;

          // Additional validation: message must have box object with expected properties
          if (
            data.message &&
            data.message.box &&
            typeof data.message.box === "object"
          ) {
            const box = data.message.box;
            // Must have either id or param_key, and must not look like list data
            if (
              (box.id || box.param_key) &&
              !box.hasOwnProperty("important") &&
              !box.hasOwnProperty("permanent")
            ) {
              handleRemoteUpdate(data.message);
            }
          }
        } catch (e) {
          // Silently ignore parse errors
        }
      };

      ws.onclose = () => {
        // Notify queue we're offline
        operationQueue.setOnline(false);

        if (wsReconnectAttempts < wsMaxReconnectAttempts) {
          const delay = Math.min(
            1000 * Math.pow(2, wsReconnectAttempts),
            30000,
          );
          wsReconnectAttempts++;
          setTimeout(connectWebSocket, delay);
        }
      };

      ws.onerror = () => {
        // onerror is always followed by onclose, so just let onclose handle it
      };
    } catch (error) {
      operationQueue.setOnline(false);
    }
  }

  // Also listen to browser online/offline events as backup
  window.addEventListener("online", () => {
    // Browser is back online, try to reconnect WebSocket
    if (!ws || ws.readyState !== WebSocket.OPEN) {
      connectWebSocket();
    }
  });

  window.addEventListener("offline", () => {
    operationQueue.setOnline(false);
  });

  function handleRemoteUpdate(data) {
    const { box, action } = data;
    if (!box) return;

    // Validate this is inventory data (must have id or param_key)
    if (!box.id && !box.param_key) return;

    // Don't process updates for items we just created (they have pending state)
    // Check by param_key first (DOM uses param_key in data-id/data-key)
    const boxKey = box.param_key || box.id;
    const existingPendingByKey =
      tree.querySelector(`li.pending[data-key='${boxKey}']`) ||
      tree.querySelector(`li.pending[data-id='${boxKey}']`);
    if (existingPendingByKey) return;

    // Also check for pending items with same name in same parent (temp IDs won't match real IDs)
    if (action === "create" || !action) {
      const parentSelector = box.parent_key
        ? `ul[data-box-id='${box.parent_key}']`
        : "ul[role=tree]";
      const parentUl = tree.querySelector(parentSelector);
      if (parentUl) {
        const pendingItems = parentUl.querySelectorAll(":scope > li.pending");
        for (const pending of pendingItems) {
          const pendingName = pending.querySelector(".item-name")?.innerText;
          if (pendingName === box.name) {
            // This is our optimistic item - update it with real data instead of creating duplicate
            pending.classList.remove("pending");
            pending.dataset.id = box.id;
            pending.dataset.key = box.param_key;
            pending.dataset.hierarchy = box.hierarchy;
            const ul = pending.querySelector("ul[data-box-id]");
            if (ul) ul.dataset.boxId = box.param_key || box.id;
            return;
          }
        }
      }
    }

    // Skip repositioning for items we recently moved locally
    // (our own WebSocket broadcast would have stale sibling sort_orders)
    const skipReposition = wasRecentlyMoved(boxKey);
    upsertBox(box, { skipReposition });
  }

  // Connect WebSocket on load
  connectWebSocket();

  // ============================================================================
  // Box CRUD Operations
  // ============================================================================

  function upsertBox(box, options = {}) {
    // Validate box data - must have id and name to be valid inventory data
    if (!box || (!box.id && !box.param_key)) {
      return;
    }
    // skipReposition: true = don't reposition element (used for local operations
    // where optimistic move already placed it correctly)
    const { skipReposition = false } = options;

    // Use param_key for lookups since data-id in DOM contains param_key
    // (Box model has self.primary_key = "param_key", so box.id in view returns param_key,
    // but as_json serializes the actual id column which is a bigint)
    const boxKey = box.param_key || box.id;

    // Handle deleted boxes early - don't create new elements for delete broadcasts
    if (box.deleted) {
      const existingLi =
        tree.querySelector(`li[data-key='${boxKey}']`) ||
        tree.querySelector(`li[data-id='${boxKey}']`);
      if (existingLi) {
        const parentLi =
          existingLi.closest(
            `li[data-key='${existingLi.dataset.parentKey}']`,
          ) ||
          existingLi.closest(`li[data-id='${existingLi.dataset.parentKey}']`);
        const ul = parentLi
          ? parentLi.querySelector(
              `ul[data-box-id='${parentLi.dataset.key || parentLi.dataset.id}']`,
            )
          : null;

        // Save state for undo
        saveStateForUndo("delete", existingLi);

        existingLi.remove();
        if (ul && !ul.querySelector("li[data-type]")) {
          updateBoxType(parentLi);
        }
      }
      // Either way, return early - don't create elements for deleted items
      return;
    }

    const existingLi =
      tree.querySelector(`li[data-key='${boxKey}']`) ||
      tree.querySelector(`li[data-id='${boxKey}']`);
    if (existingLi) {
      const oldHierarchy = existingLi.dataset.hierarchy || "";
      const oldParentKey = existingLi.dataset.parentKey || "";
      const oldSortOrder = parseInt(existingLi.dataset.sortOrder, 10) || 0;

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

      // Helper to get parent li (handles empty parent_key for top level)
      const getParentLi = (parentKey) => {
        if (!parentKey) return tree.querySelector("li[data-type='root']");
        return (
          tree.querySelector(`li[data-key='${parentKey}']`) ||
          tree.querySelector(`li[data-id='${parentKey}']`) ||
          tree.querySelector("li[data-type='root']")
        );
      };

      // Helper to get target UL for a parent
      const getTargetUl = (parentLi) => {
        if (!parentLi) return tree.querySelector("ul[role='tree']");
        if (parentLi.dataset.type === "root")
          return tree.querySelector("ul[role='tree']");
        const key = parentLi.dataset.key || parentLi.dataset.id;
        return (
          parentLi.querySelector(":scope > details > ul") ||
          parentLi.querySelector(`ul[data-box-id='${key}']`)
        );
      };

      const oldParentLi = getParentLi(oldParentKey);
      const parentChanged = oldParentKey !== (box.parent_key || "");
      const sortOrderChanged = oldSortOrder !== box.sort_order;

      // Check if new parent exists in DOM (don't fall back to root for non-root items)
      const newParentLi = box.parent_key
        ? tree.querySelector(`li[data-key='${box.parent_key}']`) ||
          tree.querySelector(`li[data-id='${box.parent_key}']`)
        : tree.querySelector("li[data-type='root']");

      // If new parent is NOT in DOM (not loaded due to lazy loading), ignore this update.
      // The correct state will be loaded when the parent is expanded.
      if (box.parent_key && !newParentLi) {
        return;
      }

      // If parent changed OR sort_order changed, reposition the element
      // Skip repositioning for local operations (optimistic move already placed it correctly)
      if (!skipReposition && (parentChanged || sortOrderChanged)) {
        const targetUl = getTargetUl(newParentLi);

        if (targetUl) {
          // Remove empty-box placeholder if present
          const emptyPlaceholder = targetUl.querySelector(
            ":scope > li.empty-box",
          );
          if (emptyPlaceholder) emptyPlaceholder.remove();

          // Find correct position based on sort_order (DESC - higher values first)
          const siblings = [
            ...targetUl.querySelectorAll(
              ":scope > li[data-type]:not([data-type='root'])",
            ),
          ];
          let insertBefore = null;
          for (const sibling of siblings) {
            if (sibling === existingLi) continue;
            const siblingOrder = parseInt(sibling.dataset.sortOrder, 10) || 0;
            if (box.sort_order > siblingOrder) {
              insertBefore = sibling;
              break;
            }
          }

          // Move element to correct position
          if (insertBefore) {
            targetUl.insertBefore(existingLi, insertBefore);
          } else {
            targetUl.appendChild(existingLi);
          }
        }

        if (parentChanged) {
          updateBoxType(oldParentLi);
          updateBoxType(newParentLi);
        }
      }

      if (oldHierarchy && oldHierarchy !== box.hierarchy) {
        propagateHierarchyChange(existingLi, oldHierarchy, box.hierarchy);
      }

      return;
    }

    // Create new element - requires name to be valid inventory data
    const template = inventoryForm.querySelector("#box-template");
    if (box && box.name && template) {
      // If parent isn't loaded, don't create the element - it will be loaded when parent is expanded
      const parentLi = box.parent_key
        ? tree.querySelector(`li[data-key='${box.parent_key}']`) ||
          tree.querySelector(`li[data-id='${box.parent_key}']`)
        : null;

      // If box has a parent_key but parent isn't in DOM, skip creating (parent not loaded)
      if (box.parent_key && !parentLi) {
        return;
      }

      const clone = template.content.cloneNode(true);
      const li = clone.querySelector("li");
      li.dataset.id = box.id;
      li.dataset.key = box.param_key;
      li.dataset.hierarchy = box.hierarchy;
      li.dataset.parentKey = box.parent_key || "";
      li.querySelector(".item-name").innerText = box.name;
      li.querySelector(".item-notes").innerText = box.notes || "";
      li.querySelector(".item-description").innerText = box.description || "";
      li.querySelector("ul[data-box-id='']").dataset.boxId =
        box.param_key || box.id;
      li.dataset.type = box.empty ? "item" : "box";

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

  function createBoxOptimistically(name, parentKey) {
    const template = inventoryForm.querySelector("#box-template");
    if (!template) return null;

    const tempId = operationQueue.generateTempId();
    const clone = template.content.cloneNode(true);
    const li = clone.querySelector("li");

    li.dataset.id = tempId;
    li.dataset.hierarchy = parentKey
      ? `${tree.querySelector(`li[data-id='${parentKey}']`)?.dataset.hierarchy || ""} > ${name}`
      : name;
    li.dataset.parentKey = parentKey || "";
    li.querySelector(".item-name").innerText = name;

    // Set up the inner ul and remove any loading placeholder
    const innerUl = li.querySelector("ul[data-box-id='']");
    innerUl.dataset.boxId = tempId;
    innerUl.innerHTML = '<li class="empty-box">• &lt;empty&gt;</li>';

    // Mark the details as loaded (no need to fetch since this is a new empty item)
    const innerDetails = li.querySelector("details");
    if (innerDetails) {
      innerDetails.classList.add("loaded");
    }

    li.dataset.type = "item";
    li.classList.add("pending");

    const parentLi = parentKey
      ? tree.querySelector(`li[data-id='${parentKey}']`)
      : null;
    const ul = parentLi
      ? parentLi.querySelector(`ul[data-box-id='${parentKey}']`)
      : tree.querySelector("ul[role=tree]");

    if (ul) {
      if (parentLi) {
        // Remove empty placeholder from direct children only
        ul.querySelector(":scope > .empty-box")?.remove();
        ul.prepend(li);
        // Update parent type AFTER child is added
        updateBoxType(parentLi);
        // Expand the parent box to show the new item
        const parentDetails = parentLi.querySelector(":scope > details");
        if (parentDetails && !parentDetails.open) {
          parentDetails.open = true;
        }
      } else {
        const rootEl = ul.querySelector("[data-type=root]");
        if (rootEl) {
          rootEl.after(li);
        } else {
          ul.prepend(li);
        }
      }
      attachDetailsToggleListeners();
      ensureDraggableRoots();
    }

    return { li, tempId };
  }

  function updateBoxType(li) {
    if (!li || isRootLi(li)) return;
    const ul = targetUlFor(li);
    // Only check direct children for data-type items
    const hasKids = !!ul && ul.querySelector(":scope > li[data-type]");
    const wasBox = li.dataset.type === "box";
    li.dataset.type = hasKids ? "box" : "item";

    // If box became empty (was box, now item), collapse it
    if (wasBox && !hasKids) {
      const details = li.querySelector(":scope > details");
      if (details) {
        details.open = false;
      }
    }

    if (!ul) return;
    // Only target direct child empty-box elements
    if (!hasKids && !ul.querySelector(":scope > .empty-box")) {
      const emptyLi = document.createElement("li");
      emptyLi.classList.add("empty-box");
      emptyLi.innerHTML = "• &lt;empty&gt;";
      ul.appendChild(emptyLi);
    } else if (hasKids) {
      ul.querySelector(":scope > .empty-box")?.remove();
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
    walker.nextNode();
    let node = walker.currentNode;
    while (node) {
      const h = node.dataset?.hierarchy || "";
      if (h.startsWith(prefix)) {
        node.dataset.hierarchy = `${newH} > ${h.slice(prefix.length)}`;
      }
      node = walker.nextNode();
    }

    const selected = document.querySelector("li[data-type].selected");
    if (selected && parentLi.contains(selected)) {
      const codeEl = document.querySelector(".inventory-nav code.hierarchy");
      if (codeEl) codeEl.innerText = selected.dataset.hierarchy || "";
    }
  }

  // ============================================================================
  // Smart Parsing for Quick Add
  // ============================================================================

  function parseSmartInput(input) {
    // Pattern: "Path > Path: Item1, Item2, Item3"
    const pathMatch = input.match(/^(.+?):\s*(.+)$/);
    if (pathMatch) {
      const pathPart = pathMatch[1].trim();
      const itemsPart = pathMatch[2].trim();
      const path = pathPart.split(/\s*>\s*/);
      const items = itemsPart.split(/\s*,\s*/).filter((i) => i);
      return { path, items };
    }

    // Pattern: "Path > Path > Path" - nested containers (no colon)
    if (input.includes(">")) {
      const parts = input.split(/\s*>\s*/).filter((i) => i);
      // All parts become nested path, last one is the final item
      const path = parts.slice(0, -1);
      const items = [parts[parts.length - 1]];
      return { path, items };
    }

    // Pattern: "Item1, Item2, Item3" - multiple items in current selection
    if (input.includes(",")) {
      const items = input.split(/\s*,\s*/).filter((i) => i);
      return { path: [], items };
    }

    // Single item
    return { path: [], items: [input] };
  }

  function createItemsWithPath(parsed, parentKey) {
    let currentParentKey = parentKey;
    let currentParentLi = parentKey
      ? tree.querySelector(`li[data-id='${parentKey}']`)
      : null;
    const createdItems = [];

    // Create path containers if needed
    for (const pathPart of parsed.path) {
      // Check if this container already exists
      const existingContainer = findBoxByNameInParent(
        pathPart,
        currentParentKey,
      );
      if (existingContainer) {
        currentParentKey = existingContainer.dataset.id;
        currentParentLi = existingContainer;
        continue;
      }

      // Create the container - pass the parent li directly for reliable nesting
      const result = createBoxOptimisticallyWithParent(
        pathPart,
        currentParentKey,
        currentParentLi,
      );
      if (result) {
        createdItems.push({
          tempId: result.tempId,
          serverParentKey: currentParentKey,
          li: result.li,
        });
        // Use this element as the parent for the next nested item
        currentParentKey = result.tempId;
        currentParentLi = result.li;
      }
    }

    // Create all leaf items
    // Reverse the items so they appear in the order written (since each is prepended)
    const reversedItems = [...parsed.items].reverse();
    for (const itemName of reversedItems) {
      const result = createBoxOptimisticallyWithParent(
        itemName,
        currentParentKey,
        currentParentLi,
      );
      if (result) {
        createdItems.push({
          tempId: result.tempId,
          serverParentKey: currentParentKey,
          li: result.li,
        });
      }
    }

    // Queue all operations sequentially
    const tempToServerKey = new Map();

    createdItems.forEach((item) => {
      // Capture name NOW, not at execution time (DOM might change if item is moved)
      const itemName = item.li.querySelector(".item-name")?.innerText || "";

      const resolveParentKey = () => {
        if (!item.serverParentKey) return "";
        if (item.serverParentKey.startsWith("temp_")) {
          return (
            tempToServerKey.get(item.serverParentKey) || item.serverParentKey
          );
        }
        return item.serverParentKey;
      };

      const operation = {
        type: "create",
        url: inventoryForm.action,
        method: "POST",
        getBody: () => ({
          name: itemName,
          parent_key: resolveParentKey(),
        }),
        tempId: item.tempId,
        onSuccess: (data) => {
          if (data.data) {
            tempToServerKey.set(
              item.tempId,
              data.data.param_key || data.data.id,
            );
          }
        },
      };

      operationQueue.registerPending(item.tempId, item.li, operation);
      operationQueue.add(operation);
    });
  }

  // Version that accepts parent li directly for reliable nesting
  function createBoxOptimisticallyWithParent(name, parentKey, parentLi) {
    const template = inventoryForm.querySelector("#box-template");
    if (!template) return null;

    const tempId = operationQueue.generateTempId();
    const clone = template.content.cloneNode(true);
    const li = clone.querySelector("li");

    li.dataset.id = tempId;
    li.dataset.hierarchy = parentLi
      ? `${parentLi.dataset.hierarchy || ""} > ${name}`
      : parentKey
        ? `${tree.querySelector(`li[data-id='${parentKey}']`)?.dataset.hierarchy || ""} > ${name}`
        : name;
    li.dataset.parentKey = parentKey || "";
    li.querySelector(".item-name").innerText = name;

    // Set up the inner ul and remove any loading placeholder
    const innerUl = li.querySelector("ul[data-box-id='']");
    innerUl.dataset.boxId = tempId;
    innerUl.innerHTML = '<li class="empty-box">• &lt;empty&gt;</li>';

    // Mark the details as loaded (no need to fetch since this is a new empty item)
    const innerDetails = li.querySelector("details");
    if (innerDetails) {
      innerDetails.classList.add("loaded");
    }

    li.dataset.type = "item";
    li.classList.add("pending");

    // Find the target ul - use parentLi directly if provided
    const ul = parentLi
      ? parentLi.querySelector(`:scope > details > ul`)
      : parentKey
        ? tree
            .querySelector(`li[data-id='${parentKey}']`)
            ?.querySelector(`:scope > details > ul`)
        : tree.querySelector("ul[role=tree]");

    if (ul) {
      if (parentLi || parentKey) {
        const actualParentLi =
          parentLi || tree.querySelector(`li[data-id='${parentKey}']`);
        // Remove empty placeholder from direct children only
        ul.querySelector(":scope > .empty-box")?.remove();
        ul.prepend(li);
        // Update parent type AFTER child is added
        updateBoxType(actualParentLi);
        // Expand the parent box to show the new item
        const parentDetails = actualParentLi?.querySelector(":scope > details");
        if (parentDetails && !parentDetails.open) {
          parentDetails.open = true;
        }
      } else {
        const rootEl = ul.querySelector("[data-type=root]");
        if (rootEl) {
          rootEl.after(li);
        } else {
          ul.prepend(li);
        }
      }
      attachDetailsToggleListeners();
      ensureDraggableRoots();
    }

    return { li, tempId };
  }

  function findBoxByNameInParent(name, parentKey) {
    const parentLi = parentKey
      ? tree.querySelector(`li[data-id='${parentKey}']`)
      : null;
    const ul = parentLi
      ? parentLi.querySelector(`ul[data-box-id='${parentKey}']`)
      : tree.querySelector("ul[role=tree]");

    if (!ul) return null;

    const items = ul.querySelectorAll(":scope > li[data-type]");
    for (const item of items) {
      const itemName = item.querySelector(".item-name")?.innerText;
      if (itemName?.toLowerCase() === name.toLowerCase()) {
        return item;
      }
    }
    return null;
  }

  // ============================================================================
  // Undo/Redo Support
  // ============================================================================

  function saveStateForUndo(action, element) {
    const state = {
      action,
      timestamp: Date.now(),
      data: {
        id: element.dataset.id,
        name: element.querySelector(".item-name")?.innerText,
        notes: element.querySelector(".item-notes")?.innerText,
        description: element.querySelector(".item-description")?.innerText,
        parentKey: element.dataset.parentKey,
        hierarchy: element.dataset.hierarchy,
      },
    };
    History.add(state);
  }

  async function performUndo() {
    const state = History.undo();
    if (!state) return;

    if (state.action === "delete") {
      // Restore deleted item
      const operation = {
        type: "restore",
        url: "/inventory/restore",
        method: "POST",
        body: { box_id: state.data.id },
      };
      operationQueue.add(operation);
      showFlash("Restored item");
    }
  }

  async function performRedo() {
    const state = History.redo();
    if (!state) {
      showFlash("Nothing to redo");
      return;
    }
    // Redo logic would go here
  }

  // ============================================================================
  // Breadcrumbs and Search
  // ============================================================================

  function buildBreadcrumbs(selectedLi) {
    breadcrumbWrapper.innerHTML = "";

    const container = document.createElement("div");
    container.className = "breadcrumbs";

    const ul = document.createElement("ul");
    container.appendChild(ul);

    ul.appendChild(
      makeBreadcrumb("Everything", "", !selectedLi && pageHierarchy === ""),
    );

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
      `${searchModalForm.action}?q=${encodeURIComponent(q)}&within=${parentKey}&with_ancestors=1`,
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

      // Show hierarchy as clickable breadcrumbs
      const hierarchyEl = clone.querySelector(".item-hierarchy");
      if (box.hierarchy) {
        hierarchyEl.innerHTML = "";
        const parts = box.hierarchy.split(" > ");
        const ancestors = box.hierarchy_ids || [];
        parts.forEach((part, idx) => {
          if (idx > 0) {
            const sep = document.createElement("span");
            sep.className = "hierarchy-sep";
            sep.innerText = " > ";
            hierarchyEl.appendChild(sep);
          }
          const link = document.createElement("a");
          link.href = ancestors[idx] ? `/b/${ancestors[idx]}` : "/inventory";
          link.className = "hierarchy-link";
          link.innerText = part;
          link.onclick = (e) => {
            e.stopPropagation();
          };
          hierarchyEl.appendChild(link);
        });
      } else {
        hierarchyEl.innerText = box.hierarchy || "";
      }

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

  // ============================================================================
  // Drag and Drop
  // ============================================================================

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
      // Filter out the node being moved - indexHint was calculated from filtered rows
      const rows = containerRows(containerUl).filter((r) => r !== node);
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
    // Use param_key (dataset.key) not numeric id, since Box.id returns param_key
    return containerRows(containerUl)
      .map((n) => n.dataset.key)
      .filter((k) => k && !k.startsWith("temp-"));
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

      // Handle multi-select drag
      if (
        selectionManager.hasSelection() &&
        selectionManager.selected.has(li.dataset.id)
      ) {
        // Dragging selected items
        dragEl = li;
        li.classList.add("dragging");
        selectionManager.selected.forEach((id) => {
          const el = tree.querySelector(`li[data-id='${id}']`);
          if (el) el.classList.add("dragging");
        });
      } else {
        // Clear selection and drag single item
        selectionManager.clear();
        dragEl = li;
        li.classList.add("dragging");
      }

      evt.dataTransfer.setData("text/plain", li.dataset.id || "");
      evt.dataTransfer.effectAllowed = "move";
    });

    document.addEventListener("dragend", () => {
      document.querySelectorAll(".dragging").forEach((el) => {
        el.classList.remove("dragging");
      });
      dragEl = null;
      clearInto();
      clearGuide();
    });

    document.addEventListener("dragover", (evt) => {
      if (!dragEl) return;

      const row = evt.target.closest("li[data-type]");
      // Prevent dropping into descendants, but allow dropping into ancestors
      if (row && row !== dragEl && !dragEl.contains(row)) {
        evt.preventDefault();

        let slot = slotFromEvent(evt, row);
        if (isRootLi(row)) slot = "into";

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

      const ul = evt.target.closest("ul");
      if (ul) {
        const parentLi = ul.closest("li[data-type]") || rootLi();
        if (parentLi && parentLi.contains(dragEl)) return;

        evt.preventDefault();

        // Filter out dragEl - matches drop handler logic for consistent guide position
        const rows = containerRows(ul).filter((r) => r !== dragEl);
        const wr = ul.getBoundingClientRect();
        const y = evt.clientY;

        // Helper to get the visual row element (summary for boxes, li for items)
        const getVisualEl = (li) =>
          li.querySelector(":scope > details > summary") || li;

        let insertAt = rows.length;
        for (let i = 0; i < rows.length; i += 1) {
          // For boxes, use summary rect (not full li which includes expanded children)
          const rr = getVisualEl(rows[i]).getBoundingClientRect();
          if (y < rr.top + rr.height / 2) {
            insertAt = i;
            break;
          }
        }

        const lineY =
          rows.length === 0
            ? wr.top + 6
            : insertAt === 0
              ? getVisualEl(rows[0]).getBoundingClientRect().top - 2
              : insertAt >= rows.length
                ? getVisualEl(rows[rows.length - 1]).getBoundingClientRect()
                    .bottom - 2
                : getVisualEl(rows[insertAt]).getBoundingClientRect().top - 2;

        clearInto();
        setGuideAt(lineY, wr.left, wr.width);
        evt.dataTransfer.dropEffect = "move";
      }
    });

    document.addEventListener("drop", (evt) => {
      if (!dragEl) return;
      evt.preventDefault();

      let targetUl, parentLi, insertAt, insertRef;
      let isDropIntoBox = false; // Track if we're dropping INTO a box (not between items)

      // Store original position for potential rollback
      const originalParent = dragEl.parentElement;
      const originalNextSibling = dragEl.nextSibling;
      const originalParentKey = dragEl.dataset.parentKey;

      // REMOVE dragEl from DOM first - this makes all position calculations clean
      dragEl.remove();

      const row = evt.target.closest("li[data-type]");
      // Prevent dropping into descendants, but allow dropping into ancestors
      if (row && row !== dragEl && !dragEl.contains(row)) {
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
          // dragEl already removed, so rows is clean
          const rows = containerRows(targetUl);
          const idx = rows.indexOf(row);
          insertAt =
            slot === "before"
              ? Math.max(0, idx)
              : Math.min(rows.length, idx + 1);
          insertRef = rows[insertAt] || null;
        } else {
          // Dropping INTO a box
          isDropIntoBox = true;
          parentLi = row;
          targetUl = targetUlFor(parentLi);
          if (!targetUl) {
            // Restore dragEl on failure
            originalParent.insertBefore(dragEl, originalNextSibling);
            return;
          }
          const rows = containerRows(targetUl);
          insertAt = 0;
          insertRef = rows[0] || null;
        }
      } else {
        targetUl =
          evt.target.closest("ul") ||
          document.querySelector(".tree ul[role=tree]");
        parentLi = targetUl.closest("li[data-type]") || rootLi();

        // dragEl already removed, so rows is clean
        const rows = containerRows(targetUl);
        const y = evt.clientY;
        insertAt = rows.length;
        for (let i = 0; i < rows.length; i += 1) {
          // For boxes, use summary rect (not full li which includes expanded children)
          const rowEl = rows[i];
          const visualEl =
            rowEl.querySelector(":scope > details > summary") || rowEl;
          const rr = visualEl.getBoundingClientRect();
          if (y < rr.top + rr.height / 2) {
            insertAt = i;
            break;
          }
        }
        insertRef = rows[insertAt] || null;
      }

      if (parentLi && dragEl.contains(parentLi)) {
        // Restore dragEl on failure
        originalParent.insertBefore(dragEl, originalNextSibling);
        return;
      }

      // Use originalParent since dragEl was removed from DOM
      const prevParentLi = originalParent.closest("li[data-type]") || rootLi();

      // Handle multi-select move
      const itemsToMove = selectionManager.hasSelection()
        ? selectionManager
            .getSelectedIds()
            .map((id) => tree.querySelector(`li[data-id='${id}']`))
            .filter(Boolean)
        : [dragEl];

      // When dropping INTO an unloaded box, remove the loading placeholder
      // and mark as loaded to prevent lazy loading from wiping out the moved item
      if (isDropIntoBox && targetUl) {
        const placeholder = targetUl.querySelector(":scope > li.post-load-box");
        if (placeholder) {
          placeholder.remove();
          // Mark the details as loaded so lazy loading doesn't trigger
          const details = parentLi.querySelector(":scope > details");
          if (details) {
            details.classList.remove("pending-load");
            details.classList.add("loaded");
          }
        }
        // Also remove empty-box placeholder if present
        const emptyPlaceholder = targetUl.querySelector(
          ":scope > li.empty-box",
        );
        if (emptyPlaceholder) {
          emptyPlaceholder.remove();
        }
      }

      // Use param_key (dataset.key), not numeric id, for parent_key
      const newParentKey = isRootLi(parentLi) ? "" : parentLi.dataset.key || "";

      // Optimistic move - insert at calculated position
      itemsToMove.forEach((item, idx) => {
        if (idx === 0) {
          // Insert at the exact index we calculated
          const rows = containerRows(targetUl);
          const refEl = rows[insertAt] || null;
          if (refEl) {
            targetUl.insertBefore(item, refEl);
          } else {
            targetUl.appendChild(item);
          }
        } else {
          const prev = itemsToMove[idx - 1];
          targetUl.insertBefore(item, prev.nextSibling);
        }
        // Update parentKey optimistically
        item.dataset.parentKey = newParentKey;
        // Mark as recently moved to skip repositioning on our own WebSocket broadcast
        markAsRecentlyMoved(item.dataset.key);
      });

      updateBoxType(prevParentLi);
      updateBoxType(parentLi);

      // Expand the target box so user can see where item went
      if (isDropIntoBox && !isRootLi(parentLi)) {
        const details = parentLi.querySelector(":scope > details");
        if (details && !details.open) {
          details.open = true;
        }
      }

      const movedId = dragEl.dataset.id;
      const movedKey = dragEl.dataset.key;
      const child_ids = buildChildIds(targetUl);

      // Update sort_order dataset for ALL items in the container based on new positions.
      // This prevents WebSocket updates from repositioning siblings (sortOrderChanged will be false).
      // Sort order is DESC - higher values appear first.
      const allRows = containerRows(targetUl);
      allRows.forEach((row, idx) => {
        row.dataset.sortOrder = allRows.length - idx;
      });

      // Previous state for rollback was captured at start (originalParent, originalNextSibling)
      const prevParentUl = originalParent;

      // Mark moved items as pending
      itemsToMove.forEach((item) => item.classList.add("pending"));

      // Build request body (use getBody for dynamic computation in case of retries)
      const getBody = () => {
        const body = {
          box_id: movedKey || movedId,
          parent_key: newParentKey,
          child_ids: buildChildIds(targetUl),
        };
        if (isDropIntoBox) {
          body.insert_at_top = true;
        }
        return body;
      };

      // Create move operation for the queue
      const moveOperation = {
        type: "move",
        url: editBoxForm.action,
        method: "PATCH",
        getBody,
        tempId: `move_${movedId}_${Date.now()}`,
        onSuccess: (data) => {
          itemsToMove.forEach((item) =>
            item.classList.remove("pending", "error"),
          );
          if (data.data) {
            // Skip repositioning - optimistic move already placed it correctly
            // (sibling sort_orders in DOM are stale, would cause incorrect placement)
            upsertBox(data.data, { skipReposition: true });
          }
        },
        onError: (err) => {
          // Rollback: move items back to original position
          itemsToMove.forEach((item) => {
            item.classList.remove("pending");
            item.classList.add("error");
            item.dataset.parentKey = originalParentKey;
          });
          if (prevParentUl) {
            itemsToMove.forEach((item) => {
              if (originalNextSibling) {
                prevParentUl.insertBefore(item, originalNextSibling);
              } else {
                prevParentUl.appendChild(item);
              }
            });
            updateBoxType(prevParentLi);
            updateBoxType(parentLi);
          }
          showFlash(err.message || "Move failed - reverted");
        },
      };

      // Register and add to queue for offline/retry support
      operationQueue.registerPending(
        moveOperation.tempId,
        dragEl,
        moveOperation,
      );
      operationQueue.add(moveOperation);

      // Clean up drag state
      clearInto();
      clearGuide();
      document.querySelectorAll(".dragging").forEach((el) => {
        el.classList.remove("dragging");
      });
      dragEl = null;
      selectionManager.clear();
    });

    // ==========================================================================
    // Touch Support for Mobile Drag and Drop
    // ==========================================================================
    let touchDragEl = null;
    let touchStartY = 0;
    let touchStartX = 0;
    let touchGuide = null;
    let touchIntoRow = null;
    let longPressTimer = null;
    let isDragging = false;
    const LONG_PRESS_DURATION = 400; // ms to trigger drag
    const DRAG_THRESHOLD = 10; // px to confirm drag intent

    function touchClearGuide() {
      touchGuide?.remove();
      touchGuide = null;
    }

    function touchSetGuideAt(y, left, width) {
      if (!touchGuide) {
        touchGuide = document.createElement("div");
        touchGuide.className = "drop-guide";
        document.body.appendChild(touchGuide);
      }
      touchGuide.style.top = `${y}px`;
      touchGuide.style.left = `${left}px`;
      touchGuide.style.width = `${width}px`;
    }

    function touchClearInto() {
      touchIntoRow?.classList.remove("into-target");
      touchIntoRow = null;
    }

    function cancelTouchDrag() {
      if (longPressTimer) {
        clearTimeout(longPressTimer);
        longPressTimer = null;
      }
      if (touchDragEl) {
        touchDragEl.classList.remove("dragging");
        selectionManager.selected.forEach((id) => {
          const el = tree.querySelector(`li[data-id='${id}']`);
          if (el) el.classList.remove("dragging");
        });
      }
      touchDragEl = null;
      isDragging = false;
      touchClearGuide();
      touchClearInto();
    }

    tree.addEventListener(
      "touchstart",
      (evt) => {
        const li = evt.target.closest("li[data-type]");
        if (!li || isRootLi(li)) return;

        // Don't start drag if touching inside a control (button, input, etc.)
        if (evt.target.closest("button, input, textarea, a, .item-actions")) {
          return;
        }

        const touch = evt.touches[0];
        touchStartX = touch.clientX;
        touchStartY = touch.clientY;
        touchDragEl = li;

        // Start long-press timer
        longPressTimer = setTimeout(() => {
          if (!touchDragEl) return;

          isDragging = true;
          // Handle multi-select drag
          if (
            selectionManager.hasSelection() &&
            selectionManager.selected.has(li.dataset.id)
          ) {
            li.classList.add("dragging");
            selectionManager.selected.forEach((id) => {
              const el = tree.querySelector(`li[data-id='${id}']`);
              if (el) el.classList.add("dragging");
            });
          } else {
            selectionManager.clear();
            li.classList.add("dragging");
          }

          // Provide haptic feedback if available
          if (navigator.vibrate) {
            navigator.vibrate(50);
          }
        }, LONG_PRESS_DURATION);
      },
      { passive: true },
    );

    tree.addEventListener(
      "touchmove",
      (evt) => {
        if (!touchDragEl) return;

        const touch = evt.touches[0];
        const dx = Math.abs(touch.clientX - touchStartX);
        const dy = Math.abs(touch.clientY - touchStartY);

        // If moved before long press, cancel drag
        if (!isDragging && (dx > DRAG_THRESHOLD || dy > DRAG_THRESHOLD)) {
          cancelTouchDrag();
          return;
        }

        if (!isDragging) return;

        evt.preventDefault(); // Prevent scrolling while dragging

        const clientY = touch.clientY;
        const clientX = touch.clientX;

        // Find element under touch point (excluding the dragged element)
        const elemBelow = document.elementFromPoint(clientX, clientY);
        if (!elemBelow) {
          touchClearInto();
          touchClearGuide();
          return;
        }

        const row = elemBelow.closest("li[data-type]");
        if (row && row !== touchDragEl && !touchDragEl.contains(row)) {
          let slot = slotFromEvent({ clientY }, row);
          if (isRootLi(row)) slot = "into";

          const summary =
            row.querySelector(":scope > details > summary") ||
            row.querySelector(":scope > summary") ||
            row;
          const r = summary.getBoundingClientRect();

          if (slot === "before") {
            touchClearInto();
            touchSetGuideAt(r.top - 2, r.left, r.width);
          } else if (slot === "after") {
            touchClearInto();
            touchSetGuideAt(r.bottom - 2, r.left, r.width);
          } else {
            touchClearGuide();
            if (!isRootLi(row)) {
              if (touchIntoRow !== row) {
                touchClearInto();
                row.classList.add("into-target");
                touchIntoRow = row;
              }
            } else {
              const topUl = document.querySelector(".tree ul[role=tree]");
              const wr = topUl.getBoundingClientRect();
              const firstReal = [...topUl.children].find(
                (n) => n.matches("li[data-type]") && !isRootLi(n),
              );
              const y = firstReal
                ? firstReal.getBoundingClientRect().top - 2
                : wr.top + 6;
              touchSetGuideAt(y, wr.left, wr.width);
            }
          }
          return;
        }

        const ul = elemBelow.closest("ul");
        if (ul && ul !== touchDragEl.parentElement) {
          const parentLi = ul.closest("li[data-type]") || rootLi();
          if (parentLi && parentLi.contains(touchDragEl)) {
            touchClearInto();
            touchClearGuide();
            return;
          }

          const rows = containerRows(ul).filter((r) => r !== touchDragEl);
          const wr = ul.getBoundingClientRect();
          const getVisualEl = (li) =>
            li.querySelector(":scope > details > summary") || li;

          let insertAt = rows.length;
          for (let i = 0; i < rows.length; i++) {
            const rr = getVisualEl(rows[i]).getBoundingClientRect();
            if (clientY < rr.top + rr.height / 2) {
              insertAt = i;
              break;
            }
          }

          const lineY =
            rows.length === 0
              ? wr.top + 6
              : insertAt === 0
                ? getVisualEl(rows[0]).getBoundingClientRect().top - 2
                : insertAt >= rows.length
                  ? getVisualEl(rows[rows.length - 1]).getBoundingClientRect()
                      .bottom - 2
                  : getVisualEl(rows[insertAt]).getBoundingClientRect().top - 2;

          touchClearInto();
          touchSetGuideAt(lineY, wr.left, wr.width);
        }
      },
      { passive: false },
    );

    tree.addEventListener("touchend", (evt) => {
      if (longPressTimer) {
        clearTimeout(longPressTimer);
        longPressTimer = null;
      }

      if (!isDragging || !touchDragEl) {
        touchDragEl = null;
        isDragging = false;
        return;
      }

      evt.preventDefault();

      const touch = evt.changedTouches[0];
      const clientX = touch.clientX;
      const clientY = touch.clientY;

      // Find drop target
      const elemBelow = document.elementFromPoint(clientX, clientY);
      if (!elemBelow) {
        cancelTouchDrag();
        return;
      }

      // Simulate a drop by dispatching a synthetic drop event data
      // and calling the same logic as the mouse drop handler
      const row = elemBelow.closest("li[data-type]");
      const ul = elemBelow.closest("ul");

      if (!row && !ul) {
        cancelTouchDrag();
        return;
      }

      // Build items to move (same as mouse handler)
      const itemsToMove = selectionManager.hasSelection()
        ? Array.from(selectionManager.selected)
            .map((id) => tree.querySelector(`li[data-id='${id}']`))
            .filter(Boolean)
        : [touchDragEl];

      // Store original position for potential rollback
      const originalParent = touchDragEl.parentElement;
      const originalNextSibling = touchDragEl.nextSibling;
      const originalParentKey = touchDragEl.dataset.parentKey;

      // Remove dragEl from DOM first
      touchDragEl.remove();

      let targetUl, parentLi, insertAt, insertRef;
      let isDropIntoBox = false;

      if (row && row !== touchDragEl && !touchDragEl.contains(row)) {
        let slot = slotFromEvent({ clientY }, row);
        if (isRootLi(row)) slot = "into";

        if (slot === "into") {
          isDropIntoBox = true;
          parentLi = row;
          targetUl = containerUlOf(parentLi);
          insertRef = null;
        } else {
          parentLi = row.parentElement?.closest("li[data-type]") || rootLi();
          targetUl = row.parentElement;
          const rows = containerRows(targetUl).filter((r) => r !== touchDragEl);
          const idx = rows.indexOf(row);
          insertAt = slot === "before" ? idx : idx + 1;
          insertRef = rows[insertAt] || null;
        }
      } else if (ul) {
        parentLi = ul.closest("li[data-type]") || rootLi();
        targetUl = ul;
        const rows = containerRows(ul).filter((r) => r !== touchDragEl);
        const getVisualEl = (li) =>
          li.querySelector(":scope > details > summary") || li;

        insertAt = rows.length;
        for (let i = 0; i < rows.length; i++) {
          const rr = getVisualEl(rows[i]).getBoundingClientRect();
          if (clientY < rr.top + rr.height / 2) {
            insertAt = i;
            break;
          }
        }
        insertRef = rows[insertAt] || null;
      } else {
        // Restore if no valid target
        if (originalNextSibling) {
          originalParent.insertBefore(touchDragEl, originalNextSibling);
        } else {
          originalParent.appendChild(touchDragEl);
        }
        cancelTouchDrag();
        return;
      }

      if (!targetUl) {
        // Restore
        if (originalNextSibling) {
          originalParent.insertBefore(touchDragEl, originalNextSibling);
        } else {
          originalParent.appendChild(touchDragEl);
        }
        cancelTouchDrag();
        return;
      }

      // Insert items
      const prevParentLi = originalParent?.closest("li[data-type]");
      const newParentKey = parentLi.dataset.key || parentLi.dataset.id || "";

      itemsToMove.forEach((item) => {
        if (insertRef) {
          targetUl.insertBefore(item, insertRef);
        } else if (isDropIntoBox) {
          targetUl.prepend(item);
        } else {
          targetUl.appendChild(item);
        }
        item.dataset.parentKey = newParentKey;
      });

      // Update parent box types
      updateBoxType(prevParentLi);
      updateBoxType(parentLi);

      // Expand target box if dropped into
      if (isDropIntoBox && !isRootLi(parentLi)) {
        const details = parentLi.querySelector(":scope > details");
        if (details && !details.open) {
          details.open = true;
        }
      }

      const movedId = touchDragEl.dataset.id;
      const movedKey = touchDragEl.dataset.key;

      // Update sort_order for all items
      const allRows = containerRows(targetUl);
      allRows.forEach((r, idx) => {
        r.dataset.sortOrder = allRows.length - idx;
      });

      // Mark moved items as pending
      itemsToMove.forEach((item) => item.classList.add("pending"));

      // Build and queue request
      const getBody = () => {
        const body = {
          box_id: movedKey || movedId,
          parent_key: newParentKey,
          child_ids: buildChildIds(targetUl),
        };
        if (isDropIntoBox) {
          body.insert_at_top = true;
        }
        return body;
      };

      const moveOperation = {
        type: "move",
        url: editBoxForm.action,
        method: "PATCH",
        getBody,
        tempId: `move_${movedId}_${Date.now()}`,
        onSuccess: (data) => {
          itemsToMove.forEach((item) =>
            item.classList.remove("pending", "error"),
          );
          if (data.data) {
            upsertBox(data.data, { skipReposition: true });
          }
        },
        onError: (err) => {
          itemsToMove.forEach((item) => {
            item.classList.remove("pending");
            item.classList.add("error");
            item.dataset.parentKey = originalParentKey;
          });
          if (originalParent) {
            itemsToMove.forEach((item) => {
              if (originalNextSibling) {
                originalParent.insertBefore(item, originalNextSibling);
              } else {
                originalParent.appendChild(item);
              }
            });
            updateBoxType(prevParentLi);
            updateBoxType(parentLi);
          }
          showFlash(err.message || "Move failed - reverted");
        },
      };

      operationQueue.registerPending(
        moveOperation.tempId,
        touchDragEl,
        moveOperation,
      );
      operationQueue.add(moveOperation);

      // Clean up
      cancelTouchDrag();
      selectionManager.clear();
    });

    tree.addEventListener("touchcancel", () => {
      cancelTouchDrag();
    });
  }

  // ============================================================================
  // Keyboard Shortcuts
  // ============================================================================

  let focusedIndex = -1;

  function getNavigableItems() {
    // Only return visible items (not inside collapsed details)
    return [
      ...tree.querySelectorAll("li[data-type]:not([data-type='root'])"),
    ].filter((li) => {
      // Check if any ancestor details is closed
      let parent = li.parentElement;
      while (parent && parent !== tree) {
        if (parent.tagName === "DETAILS" && !parent.open) {
          return false;
        }
        parent = parent.parentElement;
      }
      return true;
    });
  }

  function getFocusedItem() {
    const items = getNavigableItems();
    return items[focusedIndex] || null;
  }

  function scrollIntoViewWithOffset(element) {
    // Account for fixed nav bar when determining if element is visible
    const navBar = document.querySelector(".inventory-nav");
    const navHeight = navBar ? navBar.offsetHeight + 10 : 110;
    const rect = element.getBoundingClientRect();
    const viewportHeight = window.innerHeight;

    if (rect.top < navHeight) {
      // Element is behind or above the nav bar - use "start" which respects scroll-margin-top
      element.scrollIntoView({ behavior: "smooth", block: "start" });
    } else if (rect.bottom > viewportHeight) {
      // Element is below the viewport
      element.scrollIntoView({ behavior: "smooth", block: "end" });
    }
    // Otherwise element is fully visible, no scroll needed
  }

  function setFocusedItem(li, alsoSelect = true) {
    const items = getNavigableItems();
    focusedIndex = items.indexOf(li);
    items.forEach((item, idx) => {
      if (idx === focusedIndex) {
        item.classList.add("keyboard-focus");
        scrollIntoViewWithOffset(item);
      } else {
        item.classList.remove("keyboard-focus");
      }
    });
    // Also select the item so new items get added to the focused box
    if (alsoSelect && li && !isRootLi(li)) {
      selectBox(li);
    }
  }

  function navigateUp(extendSelection = false) {
    const items = getNavigableItems();
    if (items.length === 0) return;
    const previousIndex = focusedIndex;
    focusedIndex = Math.max(0, focusedIndex - 1);
    const targetItem = items[focusedIndex];

    if (extendSelection && targetItem) {
      // Initialize selection with current item if nothing selected
      if (selectionManager.selected.size === 0 && items[previousIndex]) {
        selectionManager.toggle(items[previousIndex]);
      }
      selectionManager.toggle(targetItem);
    }

    setFocusedItem(targetItem, !extendSelection);
  }

  function navigateDown(extendSelection = false) {
    const items = getNavigableItems();
    if (items.length === 0) return;
    const previousIndex = focusedIndex;
    focusedIndex = Math.min(items.length - 1, focusedIndex + 1);
    const targetItem = items[focusedIndex];

    if (extendSelection && targetItem) {
      // Initialize selection with current item if nothing selected
      if (selectionManager.selected.size === 0 && items[previousIndex]) {
        selectionManager.toggle(items[previousIndex]);
      }
      selectionManager.toggle(targetItem);
    }

    setFocusedItem(targetItem, !extendSelection);
  }

  function expandFocused() {
    const item = getFocusedItem();
    if (!item) return;
    const details = item.querySelector(":scope > details");
    if (details && !details.open) {
      details.open = true;
    }
  }

  function expandAllLoaded(item) {
    // Expand this item and all already-loaded nested boxes
    if (!item) item = getFocusedItem();
    if (!item) return;

    const details = item.querySelector(":scope > details");
    if (details) {
      details.open = true;
      // Recursively expand all loaded children
      const childBoxes = details.querySelectorAll("li[data-type='box']");
      childBoxes.forEach((child) => {
        const childDetails = child.querySelector(":scope > details");
        if (childDetails && childDetails.classList.contains("loaded")) {
          childDetails.open = true;
        }
      });
    }
  }

  function collapseFocused() {
    const item = getFocusedItem();
    if (!item) return;
    const details = item.querySelector(":scope > details");

    // If this item has an open details, close it
    if (details && details.open) {
      details.open = false;
      return;
    }

    // Otherwise, move to parent box and close it
    const parentLi = item.parentElement?.closest(
      "li[data-type='box'], li[data-type='root']",
    );
    if (parentLi && !isRootLi(parentLi)) {
      setFocusedItem(parentLi);
      const parentDetails = parentLi.querySelector(":scope > details");
      if (parentDetails && parentDetails.open) {
        parentDetails.open = false;
      }
    }
  }

  function collapseAllNested(item) {
    // Collapse this item and all nested boxes
    if (!item) item = getFocusedItem();
    if (!item) return;

    const details = item.querySelector(":scope > details");
    if (details) {
      // First collapse all children recursively
      const allNestedDetails = details.querySelectorAll("details");
      allNestedDetails.forEach((d) => {
        d.open = false;
      });
      // Then collapse this one
      details.open = false;
    }
  }

  function selectFocused() {
    const item = getFocusedItem();
    if (item) {
      selectBox(item);
    }
  }

  function deleteBox(item) {
    if (!item || isRootLi(item)) return;

    const itemName = item.querySelector(".item-name")?.innerText || "this item";
    if (
      !confirm(
        `Are you sure you want to delete "${itemName}" and ALL of its contents? This is PERMANENT.`,
      )
    ) {
      return;
    }

    saveStateForUndo("delete", item);

    // Optimistically remove the item
    const parentLi = item.parentElement?.closest("li[data-type]");
    const nextSibling = item.nextElementSibling;
    const parentElement = item.parentElement;
    item.remove();
    updateBoxType(parentLi);

    // Select the parent box after deletion
    if (parentLi) {
      if (isRootLi(parentLi)) {
        // If parent is root, just clear the selection display
        inventoryForm.querySelector("#new_box_parent_key").value = "";
        searchWrapper.querySelector("code.hierarchy").innerText = "Everything";
      } else {
        setFocusedItem(parentLi);
      }
    }

    fetch(editBoxForm.action, {
      method: "DELETE",
      headers: {
        accept: "application/json",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ box_id: item.dataset.id }),
    })
      .then((r) => {
        if (!r.ok) throw new Error("Delete failed");
        return r.json();
      })
      .catch((err) => {
        // Restore the item on failure
        if (nextSibling) {
          parentElement?.insertBefore(item, nextSibling);
        } else {
          parentElement?.appendChild(item);
        }
        updateBoxType(parentLi);
        showFlash(err.message || "Delete failed");
      });
  }

  function deleteFocused() {
    // Check for bulk selection first
    if (selectionManager.selected.size > 1) {
      deleteSelectedItems();
      return;
    }
    deleteBox(getFocusedItem());
  }

  function deleteSelectedItems() {
    const selectedIds = Array.from(selectionManager.selected);
    const items = selectedIds
      .map((id) => tree.querySelector(`li[data-id='${id}']`))
      .filter((li) => li && !isRootLi(li));

    if (items.length === 0) return;

    // Build confirmation message
    const names = items.map(
      (li) => li.querySelector(".item-name")?.innerText || "item",
    );
    let message;
    if (names.length <= 3) {
      message = `Are you sure you want to delete "${names.join('", "')}" and ALL of their contents? This is PERMANENT.`;
    } else {
      const firstThree = names.slice(0, 3).join('", "');
      const remaining = names.length - 3;
      message = `Are you sure you want to delete "${firstThree}" and ${remaining} other item${remaining > 1 ? "s" : ""}, including ALL of their contents? This is PERMANENT.`;
    }

    if (!confirm(message)) {
      return;
    }

    // Save state for undo (save first item as reference)
    saveStateForUndo("bulk-delete", items[0]);

    // Optimistically remove all items
    const restorationInfo = items.map((item) => ({
      item,
      parentElement: item.parentElement,
      nextSibling: item.nextElementSibling,
      parentLi: item.parentElement?.closest("li[data-type]"),
    }));

    items.forEach((item) => {
      const parentLi = item.parentElement?.closest("li[data-type]");
      item.remove();
      updateBoxType(parentLi);
    });

    // Clear selection
    selectionManager.clear();

    // Select parent of first item if available
    const firstParent = restorationInfo[0]?.parentLi;
    if (firstParent) {
      if (isRootLi(firstParent)) {
        inventoryForm.querySelector("#new_box_parent_key").value = "";
        searchWrapper.querySelector("code.hierarchy").innerText = "Everything";
      } else {
        setFocusedItem(firstParent);
      }
    }

    // Delete all items on server
    Promise.all(
      items.map((item) =>
        fetch(editBoxForm.action, {
          method: "DELETE",
          headers: {
            accept: "application/json",
            "Content-Type": "application/json",
          },
          body: JSON.stringify({ box_id: item.dataset.id }),
        }).then((r) => {
          if (!r.ok) throw new Error(`Delete failed for ${item.dataset.id}`);
          return r.json();
        }),
      ),
    ).catch((err) => {
      // Restore all items on failure
      restorationInfo.forEach(({ item, parentElement, nextSibling, parentLi }) => {
        if (nextSibling) {
          parentElement?.insertBefore(item, nextSibling);
        } else {
          parentElement?.appendChild(item);
        }
        updateBoxType(parentLi);
      });
      showFlash(err.message || "Delete failed");
    });
  }

  function openEditModal() {
    showModal("edit-modal");
    // Focus the name field after modal opens
    setTimeout(() => {
      editBoxForm.querySelector("input[name='name']")?.focus();
    }, 50);
  }

  function closeEditModal() {
    // Blur all fields before closing so keyboard shortcuts work
    editModal?.querySelectorAll("input, textarea").forEach((el) => el.blur());
    hideModal("edit-modal");
    editBoxForm.reset();
  }

  function editFocused() {
    const item = getFocusedItem();
    if (item && !isRootLi(item)) {
      selectBox(item);
      openEditModal();
    }
  }

  document.addEventListener("keydown", (evt) => {
    const isInNewItemField = evt.target === newBoxField;
    const isInInput = evt.target.matches("input, textarea");

    // Handle arrow up/down in the new item field - navigate items but keep focus
    if (
      isInNewItemField &&
      (evt.key === "ArrowUp" || evt.key === "ArrowDown")
    ) {
      evt.preventDefault();
      evt.stopPropagation();
      if (evt.key === "ArrowUp") {
        navigateUp();
      } else {
        navigateDown();
      }
      // Keep focus in the text field but update visual selection
      return;
    }

    // Don't handle other shortcuts when typing in inputs
    if (isInInput) {
      // Escape from input field
      if (evt.key === "Escape") {
        evt.target.blur();
        evt.preventDefault();
      }
      return;
    }

    // Don't handle shortcuts when modal is open (except Escape)
    if (openedModal() && evt.key !== "Escape") {
      return;
    }

    const isMac = navigator.platform.toUpperCase().indexOf("MAC") >= 0;
    const ctrlKey = isMac ? evt.metaKey : evt.ctrlKey;

    switch (evt.key) {
      case "ArrowUp":
        evt.preventDefault();
        evt.stopPropagation();
        navigateUp(evt.shiftKey);
        break;
      case "ArrowDown":
        evt.preventDefault();
        evt.stopPropagation();
        navigateDown(evt.shiftKey);
        break;
      case "ArrowRight":
        evt.preventDefault();
        evt.stopPropagation();
        if (ctrlKey) {
          expandAllLoaded();
        } else {
          expandFocused();
        }
        break;
      case "ArrowLeft":
        evt.preventDefault();
        evt.stopPropagation();
        if (ctrlKey) {
          collapseAllNested();
        } else {
          collapseFocused();
        }
        break;
      case "Enter":
        evt.preventDefault();
        selectFocused();
        break;
      case "Delete":
      case "Backspace":
        if (!ctrlKey) {
          evt.preventDefault();
          deleteFocused();
        }
        break;
      case "n":
        if (!ctrlKey) {
          evt.preventDefault();
          newBoxField.focus();
        }
        break;
      case "e":
        if (!ctrlKey) {
          evt.preventDefault();
          editFocused();
        }
        break;
      case "/":
        evt.preventDefault();
        searchModal?.dispatchEvent(new Event("modal:show"));
        break;
      case "Escape":
        selectionManager.clear();
        tree.querySelectorAll(".keyboard-focus").forEach((el) => {
          el.classList.remove("keyboard-focus");
        });
        focusedIndex = -1;
        hideModal();
        break;
      case "z":
        if (ctrlKey && !evt.shiftKey) {
          evt.preventDefault();
          performUndo();
        } else if (ctrlKey && evt.shiftKey) {
          evt.preventDefault();
          performRedo();
        }
        break;
      case "a":
        if (ctrlKey) {
          evt.preventDefault();
          const focused = getFocusedItem();
          if (focused) {
            selectionManager.selectAllSiblings(focused);
          }
        }
        break;
      default:
        // Any other key focuses the new item field (except modifiers)
        if (
          !ctrlKey &&
          !evt.altKey &&
          evt.key.length === 1 &&
          evt.key !== " "
        ) {
          newBoxField.focus();
        }
    }
  });

  // ============================================================================
  // Form Handling
  // ============================================================================

  document.addEventListener("submit", (evt) => {
    const form = evt.target;
    if (!form) return;

    evt.preventDefault();

    // Handle new item form with smart parsing
    if (form === inventoryForm) {
      const inputValue = newBoxField.value.trim();
      if (!inputValue) return;

      const parentKey =
        inventoryForm.querySelector("#new_box_parent_key")?.value || "";
      const parsed = parseSmartInput(inputValue);

      if (parsed.path.length > 0 || parsed.items.length > 1) {
        // Complex input - use smart parsing
        createItemsWithPath(parsed, parentKey);
        form.reset();
        return;
      }

      // Simple single item - use optimistic create
      const result = createBoxOptimistically(parsed.items[0], parentKey);
      if (result) {
        const operation = {
          type: "create",
          url: form.action,
          method: form.method,
          body: { name: parsed.items[0], parent_key: parentKey },
          tempId: result.tempId, // Must be set before registerPending
        };
        operationQueue.registerPending(result.tempId, result.li, operation);
        operationQueue.add(operation);
      }
      form.reset();
      return;
    }

    // Handle edit form
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
          throw new Error("Invalid box (ensure name is entered)");
        }
      })
      .then((data) => {
        const box = data.data;
        upsertBox(box);
        closeEditModal();
      })
      .catch((error) => {
        showFlash(error.message);
      });
  });

  // ============================================================================
  // Page Context
  // ============================================================================

  const pageHierarchy =
    document.querySelector(".inventory-nav code.hierarchy")?.innerText.trim() ||
    "";
  const pageHierarchyParts = pageHierarchy ? pageHierarchy.split(" > ") : [];
  const pageHierarchyIds = [];

  if (pageHierarchy && tree) {
    let cur = tree.querySelector(`li[data-hierarchy='${pageHierarchy}']`);
    while (cur && !isRootLi(cur)) {
      pageHierarchyIds.unshift(cur.dataset.id);
      cur = tree.querySelector(`li[data-id='${cur.dataset.parentKey}']`);
    }
  }

  // ============================================================================
  // Modal Handling
  // ============================================================================

  if (searchModal) {
    searchModal.addEventListener("modal:show", function () {
      const selected = document.querySelector("li[data-type].selected");
      buildBreadcrumbs(selected);
      searchModal.querySelector(".modal-content")?.prepend(breadcrumbWrapper);
      showModal("search-modal");
      if (searchModalField) {
        setTimeout(() => searchModalField.focus(), 50);
      }
    });
  }

  searchModalField?.addEventListener("input", triggerSearch);

  if (breadcrumbWrapper) {
    breadcrumbWrapper.addEventListener("change", () => {
      triggerSearch();
    });
  }

  // ============================================================================
  // Click Handling
  // ============================================================================

  document.addEventListener("click", function (evt) {
    const cog = evt.target.closest(".edit-box");
    if (cog) {
      selectBox(cog.closest("li[data-type]"));
      openEditModal();
      return;
    }

    const li = evt.target.closest("li[data-type]");
    if (li) {
      // Root can be selected but not multi-selected
      if (isRootLi(li)) {
        selectionManager.clear();
        selectBox(li);
        return;
      }

      // Handle multi-select with Ctrl/Cmd or Shift
      if (evt.ctrlKey || evt.metaKey) {
        selectionManager.toggle(li);
        return;
      }
      if (evt.shiftKey) {
        selectionManager.selectRange(li);
        return;
      }

      // Single click - clear selection and select
      selectionManager.clear();
      selectBox(li);
      setFocusedItem(li);

      // Track recently viewed
      RecentlyViewed.add({
        id: li.dataset.id,
        param_key: li.dataset.key,
        name: li.querySelector(".item-name")?.innerText,
        hierarchy: li.dataset.hierarchy,
      });

      return;
    }

    const btn = evt.target.closest(".delete-button");
    if (btn) {
      evt.preventDefault();

      const boxId = editBoxForm.box_id.value;
      const existingLi = tree.querySelector(`li[data-id='${boxId}']`);

      if (existingLi) {
        closeEditModal();
        deleteBox(existingLi);
      }

      return;
    }
  });

  // ============================================================================
  // Prefetch on Hover
  // ============================================================================

  document.addEventListener("mouseover", (evt) => {
    const li = evt.target.closest("li[data-type='box']");
    if (!li) return;

    const details = li.querySelector(":scope > details");
    if (
      details &&
      !details.open &&
      details.classList.contains("pending-load")
    ) {
      prefetchCache.prefetch(li.dataset.id);
    }
  });

  // ============================================================================
  // Details Toggle (Lazy Loading)
  // ============================================================================

  function attachDetailsToggleListeners() {
    const detailsElements = document.querySelectorAll(
      ".inventory-wrapper details:not(.loaded):not(.pending-load)",
    );

    detailsElements.forEach((details) => {
      const wrapper = details.closest("li[data-id]");
      let loading = details.classList.contains("loading");
      let needsLoad =
        !loading && !!details.querySelector(":scope > ul > li.post-load-box");

      // Don't try to lazy load items with temp IDs (they're pending server creation)
      const wrapperIsPending =
        wrapper?.dataset.id?.startsWith("temp_") ||
        wrapper?.classList.contains("pending");
      if (wrapperIsPending) {
        needsLoad = false;
      }

      details.classList.add(needsLoad ? "pending-load" : "loaded");

      details.addEventListener("toggle", () => {
        if (!details.open) {
          return;
        }

        // Skip loading for pending items with temp IDs
        if (
          wrapper?.dataset.id?.startsWith("temp_") ||
          wrapper?.classList.contains("pending")
        ) {
          return;
        }

        if (loading) {
          return;
        } else if (needsLoad) {
          // Check prefetch cache first
          const cached = prefetchCache.get(wrapper?.dataset.id);
          if (cached) {
            // Use cached data
            const ul = details.querySelector(":scope > ul");
            if (ul) {
              ul.innerHTML = "";
              cached.forEach((box) => {
                const template = inventoryForm.querySelector("#box-template");
                if (template) {
                  const clone = template.content.cloneNode(true);
                  const li = clone.querySelector("li");
                  li.dataset.id = box.id;
                  li.dataset.key = box.param_key;
                  li.dataset.hierarchy = box.hierarchy;
                  li.dataset.parentKey = box.parent_key || "";
                  li.querySelector(".item-name").innerText = box.name;
                  li.querySelector(".item-notes").innerText = box.notes || "";
                  li.querySelector(".item-description").innerText =
                    box.description || "";
                  li.querySelector("ul[data-box-id='']").dataset.boxId =
                    box.param_key || box.id;
                  li.dataset.type = box.empty ? "item" : "box";
                  ul.appendChild(li);
                }
              });

              // Check if box is actually empty - if so, fix the empty attribute on server
              if (cached.length === 0 && wrapper.dataset.type !== "item") {
                fetch(editBoxForm.action, {
                  method: "PATCH",
                  headers: {
                    accept: "application/json",
                    "Content-Type": "application/json",
                  },
                  body: JSON.stringify({
                    box_id: wrapper.dataset.key || wrapper.dataset.id,
                    reset_empty: true,
                  }),
                }).catch(() => {}); // Silent fix
              }
            }
            details.classList.remove("pending-load");
            details.classList.add("loaded");
            needsLoad = false;
            updateBoxType(wrapper);
            attachDetailsToggleListeners();
            ensureDraggableRoots();
            return;
          }

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
              details.classList.remove("pending-load", "loading");
              details.classList.add("loaded");
              needsLoad = false;
              loading = false;
              updateBoxType(wrapper);
              attachDetailsToggleListeners();
              ensureDraggableRoots();

              // Check if box is actually empty - if so, fix the empty attribute on server
              const loadedUl = details.querySelector(":scope > ul");
              const hasChildren =
                loadedUl && loadedUl.querySelector(":scope > li[data-type]");
              if (!hasChildren && wrapper.dataset.type !== "item") {
                // Box was marked as having children but actually empty - fix it
                fetch(editBoxForm.action, {
                  method: "PATCH",
                  headers: {
                    accept: "application/json",
                    "Content-Type": "application/json",
                  },
                  body: JSON.stringify({
                    box_id: wrapper.dataset.key || wrapper.dataset.id,
                    reset_empty: true,
                  }),
                }).catch(() => {}); // Silent fix
              }
            })
            .catch((error) => {
              console.error("Error loading box contents:", error);
              details.classList.remove("pending-load", "loading");
              details.classList.add("load-error");
              loading = false;
            });
        }
      });
    });
  }
  attachDetailsToggleListeners();
  attachDragAndDrop();

  // ============================================================================
  // Box Selection
  // ============================================================================

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
