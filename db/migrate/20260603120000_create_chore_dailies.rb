class CreateChoreDailies < ActiveRecord::Migration[7.1]
  def change
    create_table :chore_dailies do |t|
      t.references :user,  null: false, foreign_key: { on_delete: :cascade }
      t.references :chore, null: false, foreign_key: { on_delete: :cascade }
      t.integer :sort_order, null: false, default: 0
      t.timestamps
    end

    add_index :chore_dailies, [:user_id, :chore_id], unique: true,
      name: :index_chore_dailies_on_user_id_and_chore_id
    add_index :chore_dailies, [:user_id, :sort_order],
      name: :index_chore_dailies_on_user_id_and_sort_order
  end
end
