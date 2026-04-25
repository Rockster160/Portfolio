class CreateExecutionPayloads < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def up
    create_table :execution_payloads do |t|
      t.text :code
      t.jsonb :input_data
      t.jsonb :ctx
      t.timestamps
    end

    add_column :executions, :payload_id, :bigint unless column_exists?(:executions, :payload_id)

    add_index :executions, :started_at, algorithm: :concurrently, if_not_exists: true

    execute "ALTER TABLE executions SET (fillfactor = 90)"
  end

  def down
    execute "ALTER TABLE executions RESET (fillfactor)"
    remove_index :executions, :started_at, algorithm: :concurrently, if_exists: true
    remove_column :executions, :payload_id
    drop_table :execution_payloads
  end
end
