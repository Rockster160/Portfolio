class AddSortOrderToListItems < ActiveRecord::Migration[5.0]
  def change
    add_column :list_items, :sort_order, :integer

    List.find_each do |list|
      list.list_items.each_with_index do |list_item, idx|
        list_item.update(sort_order: idx)
      end
    end
  end
end
