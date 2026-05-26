class AddExternalUidToAgendaSchedules < ActiveRecord::Migration[7.1]
  def change
    add_column :agenda_schedules, :external_uid, :text # Google event id (master)
    add_column :agenda_schedules, :external_etag, :text # for fast-skip when unchanged
    add_column :agenda_schedules, :external_updated_at, :datetime

    add_index :agenda_schedules, [:agenda_id, :external_uid],
      unique: true,
      where:  "external_uid IS NOT NULL",
      name:   "index_agenda_schedules_on_agenda_external_uid"
  end
end
