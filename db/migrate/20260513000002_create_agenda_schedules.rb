class CreateAgendaSchedules < ActiveRecord::Migration[7.1]
  def change
    create_table :agenda_schedules do |t|
      t.references :agenda, null: false, foreign_key: true, index: true
      t.string :name, null: false
      t.string :kind, null: false
      t.time :start_time, null: false
      t.integer :duration_minutes
      t.date :starts_on, null: false
      t.date :until_on
      t.jsonb :recurrence, null: false, default: {}
      t.text :notes
      t.string :location

      t.timestamps
    end
  end
end
