class RenameTable < ActiveRecord::Migration[5.0]
  def change
    rename_table :recipe_cards, :recipes
  end
end
