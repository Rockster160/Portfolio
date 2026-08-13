class AddActionToBuddyReminders < ActiveRecord::Migration[7.1]
  # A tool call to make when this comes due, instead of a line of text to say.
  #
  # `{ "tool" => "call_jil_function", "payload" => { ... } }` — the same
  # `{ tool_name:, payload: }` marker shape Buddy::ProposalBuilder replays for a
  # routine, so firing one is the existing path rather than a second one.
  #
  # Shaped like `condition` next door and for the same reasons: structured, read
  # only at fire time, and general enough that carrying a different tool later
  # needs no migration. A reminder was already the right carrier — cancel, list,
  # recurrence, the intraday window and the condition check all work on it
  # unchanged.
  def change
    add_column :buddy_reminders, :action, :jsonb
  end
end
