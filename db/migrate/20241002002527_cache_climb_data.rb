class CacheClimbData < ActiveRecord::Migration[7.1]
  def change
    add_column :climbs, :scores, :json
    add_column :climbs, :total_pennies, :integer
  end
end
