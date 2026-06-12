class AddHiddenItemIdsToAgendaPreferences < ActiveRecord::Migration[7.1]
  # Per-row hide for non-recurring items. Recurring rows already hide via
  # hidden_schedule_ids (every occurrence shares the schedule); one-off
  # rows need their own list since there's no series id to key on.
  def change
    add_column :agenda_preferences, :hidden_item_ids, :jsonb, null: false, default: []
  end
end
