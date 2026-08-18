// Feeds every (tool, status) pair through removalHint and prints the results as
// JSON for removal_hint_spec.rb. No DOM — the wording is a pure function.
import { removalHint } from "../../app/javascript/src/pages/byte/message_actions/multi_select.js";

const out = {};

// ---- a row that hasn't been tapped ---------------------------------------
out.pending = {
  cancel_reminder:       removalHint("cancel_reminder", { status: "pending" }),
  delete_event:          removalHint("delete_event", { status: "pending" }),
  remove_list_item:      removalHint("remove_list_item", { status: "pending" }),
  forget_routine:        removalHint("forget_routine", { status: "pending" }),
  forget_term:           removalHint("forget_term", { status: "pending" }),
  unlink_records:        removalHint("unlink_records", { status: "pending" }),
  undo_chore_completion: removalHint("undo_chore_completion", { status: "pending" }),
  cancel_timer:          removalHint("cancel_timer", { status: "pending" }),
  undo:                  removalHint("undo", { status: "pending" }),
};

// ---- a row that already ran and can still be walked back -----------------
out.executed_undoable = {
  cancel_reminder:       removalHint("cancel_reminder", { status: "executed", undoable: true }),
  delete_event:          removalHint("delete_event", { status: "executed", undoable: true }),
  remove_list_item:      removalHint("remove_list_item", { status: "executed", undoable: true }),
  unlink_records:        removalHint("unlink_records", { status: "executed", undoable: true }),
  undo_chore_completion: removalHint("undo_chore_completion", { status: "executed", undoable: true }),
};

// ---- everything that earns no line ---------------------------------------
out.silent = {
  // Ticking an additive row already means the obvious thing.
  log_event:          removalHint("log_event", { status: "pending" }),
  complete_chore:     removalHint("complete_chore", { status: "executed", undoable: true }),
  add_list_item:      removalHint("add_list_item", { status: "pending" }),
  create_chore:       removalHint("create_chore", { status: "pending" }),
  unknown_tool:       removalHint("some_future_tool", { status: "pending" }),
  // Ran, but there's no way back — the box is locked, so promising an untick
  // would be a lie.
  executed_locked:    removalHint("delete_event", { status: "executed", undoable: false }),
  // Finished one way or another; the strike-through and glyph carry these.
  undone:             removalHint("delete_event", { status: "undone" }),
  failed:             removalHint("delete_event", { status: "failed" }),
  expired:            removalHint("delete_event", { status: "expired" }),
  superseded:         removalHint("delete_event", { status: "superseded" }),
  working:            removalHint("delete_event", { status: "working" }),
  // Called with nothing at all, the way a row with no tool_name arrives.
  no_options:         removalHint("delete_event"),
  no_tool:            removalHint(undefined, { status: "pending" }),
};

console.log(JSON.stringify(out));
