class AddPlanAndConditionToBuddyWatches < ActiveRecord::Migration[7.1]
  def change
    add_column :buddy_watches, :condition, :jsonb
    add_column :buddy_watches, :plan_id, :string
    add_column :buddy_reminders, :plan_id, :string
    add_index :buddy_watches, [:user_id, :plan_id]
    add_index :buddy_reminders, [:user_id, :plan_id]
  end
end
