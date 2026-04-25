class PromoteLogTrackersIdToBigint < ActiveRecord::Migration[7.1]
  def up
    execute "ALTER TABLE log_trackers ALTER COLUMN id TYPE bigint"
  end

  def down
    execute "ALTER TABLE log_trackers ALTER COLUMN id TYPE integer"
  end
end
