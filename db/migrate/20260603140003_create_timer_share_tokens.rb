class CreateTimerShareTokens < ActiveRecord::Migration[7.1]
  def change
    create_table :timer_share_tokens do |t|
      t.references :user,       null: false, foreign_key: true, index: true
      t.references :timer,      null: true,  foreign_key: true, index: true
      t.references :timer_page, null: true,  foreign_key: true, index: true
      t.string   :token,       null: false
      t.integer  :access_mode, null: false, default: 0
      t.datetime :revoked_at, precision: 6
      t.datetime :expires_at, precision: 6
      t.integer  :hit_count, null: false, default: 0
      t.timestamps precision: 6
    end

    add_index :timer_share_tokens, :token, unique: true
    add_check_constraint :timer_share_tokens,
      "(timer_id IS NOT NULL)::int + (timer_page_id IS NOT NULL)::int = 1",
      name: :timer_share_tokens_target_xor
  end
end
