import { Monitor } from "./cells/monitor";

// The dashboard is a wall display that stays open for weeks, so a deploy leaves
// it running code the server no longer serves. Reloading it was a broadcast:
// task 334 fires `{reload: true}` at the Jarvis socket about three seconds after
// the new Rails boots (measured — 18:37:40 startup, 18:37:43 broadcast), and
// ActionCable will not reopen a socket a restart killed until its 12s stale
// threshold elapses. The message went out to nobody. Task 106 had already
// cleared the request flag by then, so there was nothing left to retry, which is
// why task 334 has fired and the dashboard has never once reloaded.
//
// So the dashboard ASKS, on the socket it has just re-established, instead of
// being told on one that is still down. Whatever it missed while it was gone is
// still sitting in `dashboard_reload.sha` waiting to be claimed.
//
// THREE independent things must agree before this reloads anything, and they
// fail closed — every unknown is a refusal:
//
//   1. Someone asked. `dashboard_reload.sha` is only ever armed off
//      `reload_after_deploy`, which only the spoken "reload after deploy" sets.
//      No request, no answer, and this code never runs.
//   2. The page is genuinely stale — the sha it was served differs from the one
//      it is being sent to. Both sides are `COMMIT_SHA` off Capistrano's
//      REVISION, verified in prod to be the same 40-char value the deploy
//      reports, so this is an exact comparison and not a heuristic.
//   3. This tab has not already reloaded for that sha. Kept in sessionStorage,
//      which survives the very reload it is guarding.
//
// (3) is the one that actually matters. It is the only guard that does not
// depend on the server being correct, and it caps this at ONE reload per target
// per tab no matter what arrives on the wire or how often.
export const RELOAD_STORAGE_KEY = "dashboard-reloaded-for";

// Returns `:reload` or the reason it refused. Pure, so the reasons are
// assertable — a guard nobody can see the working of is a guard nobody can
// trust with `location.reload`.
export function reloadDecision({ target, current, lastReloadedFor }) {
  if (!target) return "no-target";
  // Never reload a page that cannot tell us what it is running: with no `current`
  // there is no stale check left, and (3) alone would let a server that keeps
  // saying the same thing reload every fresh tab forever.
  if (!current) return "unknown-build";
  if (target === current) return "already-current";
  if (lastReloadedFor === target) return "already-reloaded";

  return "reload";
}

$(document).ready(function () {
  if ($(".ctr-dashboard").length == 0) {
    return;
  }

  // Storage being unavailable (private mode, disabled cookies) means we cannot
  // remember having reloaded, so we cannot promise not to do it twice. A stale
  // dashboard is a far smaller problem than one caught in a reload loop, so the
  // unreadable case declines rather than proceeding without the guard.
  const lastReloadedFor = function () {
    try {
      return window.sessionStorage.getItem(RELOAD_STORAGE_KEY);
    } catch (err) {
      return null;
    }
  };
  const rememberReload = function (sha) {
    try {
      window.sessionStorage.setItem(RELOAD_STORAGE_KEY, sha);
      return window.sessionStorage.getItem(RELOAD_STORAGE_KEY) === sha;
    } catch (err) {
      return false;
    }
  };

  Monitor.subscribe("dashboard-reload", {
    // Fires on subscribe when the socket is already up, and again on every
    // reconnect — which is exactly the moment a deploy-restarted dashboard is
    // able to hear an answer.
    //
    // The build we are running goes WITH the question. Both facts the server
    // answers from are then durable and true at the instant it is asked, which
    // is what makes the answer independent of when anything else reconnected.
    connected: function () {
      this.resync({ sha: window.DASHBOARD_SHA });
    },
    disconnected: function () {},
    received: function (json) {
      const target = json && json.data && json.data.reload_to;
      const decision = reloadDecision({
        target: target,
        current: window.DASHBOARD_SHA,
        lastReloadedFor: lastReloadedFor(),
      });

      if (decision !== "reload") {
        return console.log(`[deploy-reload] skipped: ${decision}`);
      }
      // Write the guard BEFORE reloading, and confirm it stuck. If the write
      // silently failed we would come back up with no record and reload again,
      // and again.
      if (!rememberReload(target)) {
        return console.log("[deploy-reload] skipped: guard-unwritable");
      }

      console.log(`[deploy-reload] reloading for ${target}`);
      window.location.reload();
    },
  });
});
