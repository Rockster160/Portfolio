class AddWhitelistToBannedIp < ActiveRecord::Migration[7.0]
  def change
    add_column :banned_ips, :whitelisted, :boolean, default: false
  end
end
