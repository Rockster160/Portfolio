class AddDeletedAtToListItems < ActiveRecord::Migration[5.0]
  def change
    add_column :list_items, :formatted_name, :string
    add_column :list_items, :deleted_at, :datetime
    add_index :list_items, :deleted_at

    ListItem.find_each do |list_item|
      list_item.send(:set_formatted_name)
      list_item.save
    end
  end
end
