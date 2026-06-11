class AddSourceItemToScheduledTriggers < ActiveRecord::Migration[7.1]
  # Derived ScheduledTriggers: rows whose execute_at is computed from a source
  # AgendaItem's start_at + offset_seconds. AR callback on AgendaItem
  # propagates start_at changes; FK cascade handles deletes. Lets users write
  # Jil rules like "5 minutes before this event, remind me which suite" and
  # have them survive event edits / source-agenda re-syncs without bespoke
  # cache state.
  def change
    add_reference :scheduled_triggers, :source_item,
                  foreign_key: { to_table: :agenda_items, on_delete: :cascade },
                  null:        true,
                  index:       true
    add_column :scheduled_triggers, :offset_seconds, :integer
  end
end
