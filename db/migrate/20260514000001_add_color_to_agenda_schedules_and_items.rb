class AddColorToAgendaSchedulesAndItems < ActiveRecord::Migration[7.1]
  def change
    add_column :agenda_schedules, :color, :string
    add_column :agenda_items, :color, :string
  end
end
