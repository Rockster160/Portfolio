class AddDescriptionToLists < ActiveRecord::Migration[5.0]
  def change
    add_column :lists, :description, :text
  end
end
