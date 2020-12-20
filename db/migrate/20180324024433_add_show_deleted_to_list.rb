class AddShowDeletedToList < ActiveRecord::Migration[5.0]
  def change
    add_column :lists, :show_deleted, :boolean
  end
end
