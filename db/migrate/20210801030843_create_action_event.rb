class CreateActionEvent < ActiveRecord::Migration[5.0]
  def change
    create_table :action_events do |t|
      t.text :event_name
      t.belongs_to :user

      t.timestamps
    end
  end
end
