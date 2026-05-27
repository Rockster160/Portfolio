class AddFiredAtToAgendaItems < ActiveRecord::Migration[7.1]
  # Trigger firing previously stamped `completed_at` to dedupe — but that
  # also auto-checked the user-facing checkbox, which contradicts the rule
  # that the checkbox is only ever toggled by an explicit click.
  # `fired_at` decouples "this trigger ran" from "the user marked it done."
  def up
    add_column :agenda_items, :fired_at, :datetime
    add_index :agenda_items, :fired_at, where: "fired_at IS NOT NULL"

    # Backfill: for already-fired trigger rows (which historically used
    # `completed_at` as the fired-dedup signal), copy that timestamp to
    # `fired_at` so the worker's `where(fired_at: nil)` filter doesn't
    # re-fire them on the first post-deploy tick.
    # Hardcoded kind=2 to keep this migration self-contained — avoids
    # depending on AgendaItem.kinds, which can drift over time.
    execute(<<~SQL)
      UPDATE agenda_items
         SET fired_at = completed_at
       WHERE kind = 2
         AND completed_at IS NOT NULL
         AND fired_at IS NULL
    SQL
  end

  def down
    remove_index :agenda_items, :fired_at
    remove_column :agenda_items, :fired_at
  end
end
