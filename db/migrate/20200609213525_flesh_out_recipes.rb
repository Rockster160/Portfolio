class FleshOutRecipes < ActiveRecord::Migration[5.0]
  def change
    add_column :recipes, :description, :text
    add_column :recipes, :friendly_url, :string

    create_table :recipe_favorites do |t|
      t.belongs_to :recipe
      t.belongs_to :favorited_by

      t.timestamps
    end

    create_table :recipe_shares do |t|
      t.belongs_to :recipe
      t.belongs_to :shared_to

      t.timestamps
    end
  end
end
