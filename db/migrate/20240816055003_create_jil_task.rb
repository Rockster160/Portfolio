class CreateJilTask < ActiveRecord::Migration[7.1]
  def change
    # library tasks?
    # shared task?
    create_table :jil_tasks do |t|
      t.uuid :uuid, default: -> { "uuid_generate_v4()" }
      t.belongs_to :user
      t.integer :sort_order
      t.text :name
      t.text :cron
      t.text :listener
      t.text :code
      t.boolean :enabled, default: true
      t.datetime :next_trigger_at
      t.datetime :last_trigger_at

      t.timestamps
    end

    create_table :jil_executions do |t|
      t.belongs_to :user
      t.belongs_to :jil_task
      t.integer :status, default: 0
      t.jsonb :input_data
      t.text :code
      t.jsonb :ctx
      t.datetime :started_at, default: -> { "CURRENT_TIMESTAMP" }
      t.datetime :finished_at

      t.timestamps
    end
  end
end
