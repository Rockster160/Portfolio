class ConvertFormattedNameToText < ActiveRecord::Migration[5.0]
  def change
    change_column :list_items, :formatted_name, :text
  end
end
