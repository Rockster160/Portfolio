class AgendaFollowups < ActiveRecord::Migration[7.1]
  # * agenda_preferences — per-user filter state (hidden agendas, hide-completed
  #   by kind, hide-tentative). Previously persisted in browser localStorage;
  #   moving to the DB so filter changes broadcast to every device.
  # * agendas.timezone — calendar timezone from Google's CalendarList. Needed
  #   to interpret date-only events (Google sends `start.date` with no zone
  #   info; the calendar's default tz applies).
  def change
    create_table :agenda_preferences do |t|
      t.references :user, null: false, foreign_key: true, index: { unique: true }
      t.jsonb :hidden_agenda_ids, default: [],   null: false
      t.jsonb :hide_completed,    default: {},   null: false
      t.boolean :hide_tentative,  default: false, null: false
      t.timestamps
    end

    add_column :agendas, :timezone, :string
  end
end
