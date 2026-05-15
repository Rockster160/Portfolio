class DropListItemScheduleColumns < ActiveRecord::Migration[7.1]
  def change
    remove_column :list_items, :schedule, :string
    remove_column :list_items, :schedule_next, :datetime
    remove_column :list_items, :timezone, :integer
  end
end
