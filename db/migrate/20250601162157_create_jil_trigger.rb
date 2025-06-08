class CreateJilTrigger < ActiveRecord::Migration[7.1]
  def change
    add_column :tasks, :last_status, :integer
    add_column :scheduled_triggers, :started_at, :datetime
    add_column :scheduled_triggers, :completed_at, :datetime
  end
end
