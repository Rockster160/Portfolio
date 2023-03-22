class AddStreakLengthToActionEvent < ActiveRecord::Migration[7.0]
  def change
    add_column :action_events, :streak_length, :integer
  end
end
