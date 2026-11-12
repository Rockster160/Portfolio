// Drives PendingRemovals through each situation its spec cares about and prints
// what was sent and what is still pending, as JSON for pending_removals_spec.rb.
import { PendingRemovals } from "../../app/javascript/src/pages/dashboard/cells/pending_removals.js";

const build = ({ open = true } = {}) => {
  const state = { open, clock: 0, sent: [] };
  const pending = new PendingRemovals({
    send: (packet) => state.sent.push(packet.remove),
    isOpen: () => state.open,
    retryMs: 5000,
    now: () => state.clock,
  });
  return { state, pending };
};

const out = {};

{
  const { state, pending } = build();
  pending.toggle("Milk");
  out.connected = { sent: state.sent, pending: pending.has("Milk") };
}

{
  const { state, pending } = build({ open: false });
  pending.toggle("Milk");
  pending.toggle("Eggs");
  const sentWhileClosed = [...state.sent];
  state.open = true;
  pending.flush();
  out.queued = { sentWhileClosed, sentOnOpen: state.sent };
}

{
  const { state, pending } = build();
  pending.toggle("Milk");
  pending.update(["Milk", "Eggs"]);
  out.still_there = { sent: state.sent, pending: pending.has("Milk") };
}

{
  const { state, pending } = build();
  pending.toggle("Milk");
  pending.update(["Eggs"]);
  const goneAfterUpdate = !pending.has("Milk");
  pending.update(["Milk", "Eggs"]);
  out.put_back = { goneAfterUpdate, pending: pending.has("Milk"), sent: state.sent };
}

{
  const { state, pending } = build({ open: false });
  pending.toggle("Milk");
  const undone = pending.toggle("Milk");
  state.open = true;
  pending.flush();
  out.undo = { undone, pending: pending.has("Milk"), sent: state.sent };
}

{
  const { state, pending } = build();
  pending.toggle("Milk");
  state.clock = 1000;
  const early = pending.retry();
  state.clock = 6000;
  const late = pending.retry();
  out.retry = { early, late, sent: state.sent };
}

{
  const { state, pending } = build();
  const idle = pending.retry();
  out.retry_idle = { idle, sent: state.sent };
}

console.log(JSON.stringify(out));
