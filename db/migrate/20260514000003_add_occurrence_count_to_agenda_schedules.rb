class AddOccurrenceCountToAgendaSchedules < ActiveRecord::Migration[7.1]
  def change
    add_column :agenda_schedules, :occurrence_count, :integer
  end
end
