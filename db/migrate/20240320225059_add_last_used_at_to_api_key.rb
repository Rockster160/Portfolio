class AddLastUsedAtToApiKey < ActiveRecord::Migration[7.1]
  def change
    add_column :api_keys, :last_used_at, :timestamp, default: "now()"
    add_column :api_keys, :enabled, :boolean, default: true
    ApiKey.find_each { |key| key.update(last_used_at: key.created_at) }
    change_column_null :api_keys, :last_used_at, false
  end
end
