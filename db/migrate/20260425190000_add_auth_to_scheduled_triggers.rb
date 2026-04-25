class AddAuthToScheduledTriggers < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def up
    add_column :scheduled_triggers, :auth_type, :integer unless column_exists?(:scheduled_triggers, :auth_type)
    add_column :scheduled_triggers, :auth_type_id, :integer unless column_exists?(:scheduled_triggers, :auth_type_id)
  end

  def down
    remove_column :scheduled_triggers, :auth_type_id
    remove_column :scheduled_triggers, :auth_type
  end
end
