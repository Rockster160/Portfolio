class CreateRecipeCard < ActiveRecord::Migration[5.0]
  def change
    create_table :recipe_cards do |t|
      t.belongs_to :user
      t.string :title
      t.string :kitchen_of
      t.text :ingredients
      t.text :instructions
      t.boolean :public

      t.timestamps
    end
  end
end
