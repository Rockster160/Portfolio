class AddBannedIps < ActiveRecord::Migration[7.0]
  def change
    create_table :banned_ips do |t|
      t.inet :ip

      t.timestamps
    end
  end
end
