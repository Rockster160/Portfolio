class BackfillListItemFormattedNames < ActiveRecord::Migration[7.1]
  def change
    ListItem.find_each do |list_item|
      list_item.update_columns(formatted_name: list_item.name.downcase.gsub(/[ '",.]/i, ""))
    end
  end
end
