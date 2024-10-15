class AddAuthTypeToJilExecution < ActiveRecord::Migration[7.1]
  def change
    add_column :jil_executions, :auth_type, :integer
    add_column :jil_executions, :auth_type_id, :integer
  end
end
