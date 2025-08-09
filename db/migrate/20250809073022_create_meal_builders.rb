class CreateMealBuilders < ActiveRecord::Migration[6.0]
  def change
    create_table :meal_builders do |t|
      t.references :user, null: false, foreign_key: true
      t.text :name, null: false
      t.text :parameterized_name, null: false
      t.jsonb :items, null: false, default: []
      t.timestamps
    end

    add_index :meal_builders, [:user_id, :name], unique: true
    add_index :meal_builders, [:user_id, :parameterized_name], unique: true
  end
end
