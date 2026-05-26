class AddExternalUidToAgendaItems < ActiveRecord::Migration[7.1]
  def change
    add_column :agenda_items, :external_uid, :text # Google event id (instance or one-off)
    add_column :agenda_items, :external_etag, :text
    add_column :agenda_items, :external_updated_at, :datetime

    add_index :agenda_items, [:agenda_id, :external_uid],
      unique: true,
      where:  "external_uid IS NOT NULL",
      name:   "index_agenda_items_on_agenda_external_uid"
  end
end
