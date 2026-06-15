class AddTargetCountToChores < ActiveRecord::Migration[7.1]
  def change
    add_column :chores, :target_count, :integer, default: 1, null: false
  end
end
