class AddTreeOrderToTasks < ActiveRecord::Migration[7.1]
  def change
    add_column :tasks, :tree_order, :integer

    reversible do |dir|
      dir.up do
        # Without folders, tree_order matches sort_order
        execute "UPDATE tasks SET tree_order = sort_order"
      end
    end
  end
end
