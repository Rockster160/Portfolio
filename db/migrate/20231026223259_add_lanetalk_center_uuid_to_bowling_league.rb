class AddLanetalkCenterUuidToBowlingLeague < ActiveRecord::Migration[7.0]
  def change
    add_column :bowling_leagues, :lanetalk_center_uuid, :string
    add_column :bowlers, :usbc_number, :string
    add_column :bowlers, :usbc_full_name, :string
  end
end
