class AddMetadataToRecipes < ActiveRecord::Migration[7.1]
  def change
    change_table :recipes do |t|
      t.string :servings
      t.string :prep_time
      t.string :cook_time
      t.text :notes
    end
  end
end
