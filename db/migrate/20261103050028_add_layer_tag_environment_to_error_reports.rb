class AddLayerTagEnvironmentToErrorReports < ActiveRecord::Migration[7.1]
  def up
    change_table(:error_reports, bulk: true) { |t|
      t.text :layer, null: false, default: "backend"
      t.text :tag
      t.text :environment
      t.text :release
      t.index :layer
      t.index :tag
    }

    # Every row in a database came from the environment that database serves.
    execute("UPDATE error_reports SET environment = #{connection.quote(Rails.env)}")
    execute(<<~SQL.squish)
      UPDATE error_reports SET
        layer = CASE WHEN section LIKE 'js:%' THEN 'frontend' ELSE 'backend' END,
        tag = CASE
          WHEN section LIKE 'js:%' THEN 'browser'
          WHEN section LIKE 'sidekiq:%' THEN 'job'
          WHEN section LIKE 'custom_notifier:%' OR section LIKE '%#%' THEN 'request'
          WHEN section ~ '^[a-z0-9_]+:[0-9]+$' OR section IN ('slack', 'unknown') THEN 'rescue'
          ELSE 'buddy'
        END
    SQL
  end

  def down
    change_table(:error_reports, bulk: true) { |t|
      t.remove :layer, :tag, :environment, :release
    }
  end
end
