class ConvertClimbColumn < ActiveRecord::Migration[7.1]
  def change
    remove_column :climbs, :scores
    add_column :climbs, :scores, :jsonb
  end
end
