class AddAnchorOccurrenceToScheduledTriggers < ActiveRecord::Migration[7.1]
  def change
    # Bound to the exact occurrence rather than to the anchor plus a guess at
    # which one it meant. An anchor may be hourly, daily or weekly, so there is
    # no window of "near enough" that is right for all of them - the identity is.
    add_reference :scheduled_triggers, :anchor_occurrence,
      null: true, foreign_key: { on_delete: :cascade }
  end
end
