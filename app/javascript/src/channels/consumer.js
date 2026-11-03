// Action Cable provides the framework to deal with WebSockets in Rails.
// You can generate new channels where WebSocket features live using the `bin/rails generate channel` command.

import { createConsumer, ConnectionMonitor } from "@rails/actioncable"

// A live socket is dropped and reopened once it has gone STALE_AFTER seconds
// without a ping. The library's 6 is two missed pings, which a server that has
// just booted misses routinely: every screen reconnects at once and each one
// re-runs all of its monitors, so the pings run late, the screen gives up on a
// socket that was fine, reconnects, and starts the same flood again. Only the
// "is this one dead" check is widened;
// how soon a socket that really closed is retried still uses the library's
// threshold.
const STALE_AFTER = 15

ConnectionMonitor.prototype.connectionIsStale = function () {
  const since = this.pingedAt ? this.pingedAt : this.startedAt
  return (Date.now() - since) / 1000 > STALE_AFTER
}

export default createConsumer()
