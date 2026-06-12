class AddRecurringAndPatternFiltersToAgendaPreferences < ActiveRecord::Migration[7.1]
  # Per-recurring-event hide (toggled from the details modal) and per-user
  # name-regex hides. Both ride the same Monitor broadcast as the existing
  # hidden_agenda_ids so a toggle on phone immediately reflects on laptop.
  def change
    add_column :agenda_preferences, :hidden_schedule_ids,  :jsonb, null: false, default: []
    add_column :agenda_preferences, :hidden_name_patterns, :jsonb, null: false, default: []
  end
end
