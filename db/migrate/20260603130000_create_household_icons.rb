class CreateHouseholdIcons < ActiveRecord::Migration[7.1]
  def change
    create_table :household_icons do |t|
      t.references :chore_household,    null: false, foreign_key: { on_delete: :cascade }
      t.references :uploaded_by_user,   null: false, foreign_key: { to_table: :users }
      t.text :name,     null: false
      t.text :keywords, null: false, default: ""
      t.text :image_data, null: false
      t.timestamps
    end

    add_index :household_icons, [:chore_household_id, :name], unique: true,
      name: :index_household_icons_on_chore_household_id_and_name
  end
end
