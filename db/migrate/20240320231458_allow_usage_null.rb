class AllowUsageNull < ActiveRecord::Migration[7.1]
  def change
    change_column_null :api_keys, :last_used_at, true
  end
end
