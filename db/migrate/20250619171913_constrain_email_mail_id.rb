class ConstrainEmailMailId < ActiveRecord::Migration[7.1]
  def change
    change_column_null :emails, :mail_id, false
    add_index :emails, :mail_id
    add_index :emails, [:mail_id, :timestamp]
  end
end
