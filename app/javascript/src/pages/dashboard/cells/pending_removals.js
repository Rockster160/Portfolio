// Removals the list cell has asked for but the server hasn't confirmed yet.
//
// A removal stays pending until a list update arrives without the item. While
// it is pending it is (re)sent whenever there is a chance it was lost: when it
// is first asked for, when the socket reopens, when an update still holds the
// item, and on a retry interval. Removing a name the list no longer holds is a
// no-op on the server, so sending one twice is harmless.
//
// Once an update shows the item gone it stops being tracked, so an item put
// back afterwards is left alone.
export class PendingRemovals {
  constructor({ send, isOpen, retryMs = 5000, now = () => Date.now() }) {
    this.send = send;
    this.isOpen = isOpen;
    this.retryMs = retryMs;
    this.now = now;
    this.names = new Set();
    this.lastSentAt = null;
  }

  has(name) {
    return this.names.has(name);
  }

  get size() {
    return this.names.size;
  }

  // Marks a name for removal, or cancels it when it is already pending.
  // Returns true when the name is now pending.
  toggle(name) {
    if (this.names.has(name)) {
      this.names.delete(name);
      return false;
    }

    this.names.add(name);
    this.sendOne(name);
    return true;
  }

  // Called with the item names of every list update. Drops the ones that are
  // gone and resends the ones still there.
  update(itemNames) {
    const present = new Set(itemNames);
    this.names.forEach((name) => {
      if (!present.has(name)) {
        this.names.delete(name);
      }
    });
    this.flush();
  }

  flush() {
    if (!this.isOpen()) {
      return false;
    }
    this.names.forEach((name) => this.sendOne(name));
    return this.names.size > 0;
  }

  // Resends everything pending once nothing has gone out for `retryMs`.
  retry() {
    if (this.names.size === 0) {
      return false;
    }
    if (this.lastSentAt != null && this.now() - this.lastSentAt < this.retryMs) {
      return false;
    }
    return this.flush();
  }

  sendOne(name) {
    if (!this.isOpen()) {
      return;
    }
    this.send({ remove: name });
    this.lastSentAt = this.now();
  }
}
