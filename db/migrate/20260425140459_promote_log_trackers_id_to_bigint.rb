class PromoteLogTrackersIdToBigint < ActiveRecord::Migration[7.1]
  def up
    execute "ALTER TABLE log_trackers ALTER COLUMN id TYPE bigint"
    execute "ALTER SEQUENCE log_trackers_id_seq AS bigint"
  end

  def down
    execute "ALTER SEQUENCE log_trackers_id_seq AS integer"
    execute "ALTER TABLE log_trackers ALTER COLUMN id TYPE integer"
  end
end
