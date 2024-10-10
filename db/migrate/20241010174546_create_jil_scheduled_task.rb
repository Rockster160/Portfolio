class CreateJilScheduledTask < ActiveRecord::Migration[7.1]
  def change
    create_table :jil_scheduled_triggers do |t|
      t.belongs_to :user, null: false
      t.text :trigger, null: false
      t.jsonb :data, null: false, default: {}
      t.datetime :execute_at, null: false
      t.text :jid

      t.timestamps
    end
  end
end
