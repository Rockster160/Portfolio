class ConvertListItemToText < ActiveRecord::Migration[5.0]
  def change
    change_column :list_items, :name, :text
    add_column :list_items, :amount, :integer
  end
end
