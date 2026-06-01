class AddEndedFiredAtToAgendaItems < ActiveRecord::Migration[7.1]
  def change
    add_column :agenda_items, :ended_fired_at, :datetime
  end
end
