class CreateVenmo < ActiveRecord::Migration
  def change
    create_table :venmos do |t|
      t.string :access_code
      t.string :access_token
      t.string :refresh_token
      t.datetime :expires_at

      t.timestamps
    end
  end
end
