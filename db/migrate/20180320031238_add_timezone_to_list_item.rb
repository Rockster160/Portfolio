class AddTimezoneToListItem < ActiveRecord::Migration[5.0]
  def change
    add_column :list_items, :timezone, :integer
  end
end
