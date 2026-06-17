class AddMetadataToAgendaSchedules < ActiveRecord::Migration[7.1]
  def change
    add_column :agenda_schedules, :metadata, :jsonb, default: {}, null: false
  end
end
