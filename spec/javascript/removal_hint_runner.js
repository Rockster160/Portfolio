// Feeds every (tool, status) pair through removalHint and prints the results as
// JSON for removal_hint_spec.rb. No DOM — the wording is a pure function.
import {
  removalHint,
  rowNote,
} from "../../app/javascript/src/pages/byte/message_actions/multi_select.js";

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

// ---- a row that brought its own words -------------------------------------
// A before-bed card is every row the same tool, and "Tap to remove it"
// describes the mechanism rather than what the person is doing.
const CHECK_OFF = { tap: "Tap when it's done", done: "Done - untick to put it back" };

out.override = {
  pending:  removalHint("remove_list_item", { status: "pending", override: CHECK_OFF }),
  executed: removalHint("remove_list_item", { status: "executed", undoable: true, override: CHECK_OFF }),
  // Locked and finished rows still get nothing — the override says the words,
  // never when they apply.
  locked:   removalHint("remove_list_item", { status: "executed", undoable: false, override: CHECK_OFF }),
  undone:   removalHint("remove_list_item", { status: "undone", override: CHECK_OFF }),
  // A tool with no words of its own can be given some.
  additive: removalHint("log_event", { status: "pending", override: CHECK_OFF }),
};

// ---- the one slot under a row, and what wins it ---------------------------
// The receipt used to be a message of its own posted under the card, which on a
// checklist worked through one box at a time meant one bubble per box.
const CHECKED_OFF = {
  tool_name: "remove_list_item",
  receipt: "Removed Pickup Whisper Dinner ✓",
  hint: CHECK_OFF,
};
const ADDED = { tool_name: "add_agenda_item", receipt: "Added Shower to Rockster160 ✓" };

out.note = {
  // The hint says what the tick MEANS on a list; the receipt would only say the
  // mechanism over again.
  hint_beats_receipt: rowNote(CHECKED_OFF, { status: "executed", undoable: true }),
  // No hint, so the receipt is the whole news - and it carries which list,
  // where the row's own label is just "Shower".
  receipt_when_no_hint: rowNote(ADDED, { status: "executed" }),
  // Nothing has happened yet, so there is nothing to report.
  pending_says_nothing: rowNote(ADDED, { status: "pending" }),
  // A tool that declined a receipt leaves the ✓ to say it.
  quiet_tool: rowNote({ tool_name: "log_event" }, { status: "executed" }),
  undone: rowNote({ tool_name: "log_event", undo_note: "Undone - unmarked Dishes" }, { status: "undone" }),
  failed: rowNote(ADDED, { status: "failed" }),
  // A row with no tool and no words at all still has to answer.
  empty: rowNote({}, { status: "executed" }),
  nothing: rowNote(undefined, { status: "executed" }),
};

console.log(JSON.stringify(out));
