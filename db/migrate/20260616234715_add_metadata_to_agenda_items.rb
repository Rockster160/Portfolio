class AddMetadataToAgendaItems < ActiveRecord::Migration[7.1]
  def change
    add_column :agenda_items, :metadata, :jsonb, default: {}, null: false
  end
end
