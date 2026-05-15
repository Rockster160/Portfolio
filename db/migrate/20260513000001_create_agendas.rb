class CreateAgendas < ActiveRecord::Migration[7.1]
  def change
    create_table :agendas do |t|
      t.references :user, null: false, foreign_key: true, index: true
      t.string :name, null: false
      t.string :parameterized_name, null: false
      t.string :color
      t.integer :sort_order

      t.timestamps
    end

    add_index :agendas, [:user_id, :parameterized_name], unique: true
  end
end
