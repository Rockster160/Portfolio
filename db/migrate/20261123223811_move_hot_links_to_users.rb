# Hot links become one list per person rather than one per phone: each widget
# already picks its own from the list. A person's newest non-empty phone list
# carries over.
class MoveHotLinksToUsers < ActiveRecord::Migration[7.1]
  def up
    add_column :users, :hot_links, :jsonb, null: false, default: []
    execute(
      <<~SQL.squish,
        UPDATE users SET hot_links = newest.hot_links
        FROM (
          SELECT DISTINCT ON (user_id) user_id, hot_links
          FROM app_devices
          WHERE hot_links <> '[]'::jsonb
          ORDER BY user_id, updated_at DESC
        ) newest
        WHERE newest.user_id = users.id
      SQL
    )
    remove_column :app_devices, :hot_links
  end

  def down
    add_column :app_devices, :hot_links, :jsonb, null: false, default: []
    execute(
      <<~SQL.squish,
        UPDATE app_devices SET hot_links = users.hot_links
        FROM users WHERE users.id = app_devices.user_id
      SQL
    )
    remove_column :users, :hot_links
  end
end
