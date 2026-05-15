class CreateAgendaItems < ActiveRecord::Migration[7.1]
  def change
    create_table :agenda_items do |t|
      t.references :agenda, null: false, foreign_key: true, index: true
      t.references :agenda_schedule, foreign_key: true, index: true
      t.string :kind, null: false
      t.datetime :start_at, null: false
      t.datetime :end_at
      t.datetime :completed_at
      t.datetime :detached_at
      t.string :name, null: false
      t.text :notes
      t.string :location

      t.timestamps
    end

    add_index :agenda_items, [:agenda_id, :start_at]
    add_index :agenda_items, [:agenda_schedule_id, :start_at]
    add_index :agenda_items, :completed_at
  end
end
