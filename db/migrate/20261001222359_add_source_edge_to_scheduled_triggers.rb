class AddSourceEdgeToScheduledTriggers < ActiveRecord::Migration[7.1]
  def change
    add_column :scheduled_triggers, :source_edge, :integer, null: false, default: 0

    # Rows trigger_for_end made before this column existed. The only trace of
    # them is an execute_at that sits off end_at rather than start_at - and only
    # while that still holds, so a row a move already dragged onto start_at
    # can't be told apart and stays :start.
    reversible { |dir|
      dir.up {
        execute(
          <<~SQL.squish,
            UPDATE scheduled_triggers st
            SET source_edge = 1
            FROM agenda_items ai
            WHERE st.source_item_id = ai.id
              AND st.started_at IS NULL
              AND ai.end_at IS NOT NULL
              AND ai.end_at <> ai.start_at
              AND st.execute_at = ai.end_at + make_interval(secs => st.offset_seconds)
          SQL
        )
      }
    }
  end
end
