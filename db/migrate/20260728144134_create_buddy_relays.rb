class CreateBuddyRelays < ActiveRecord::Migration[7.1]
  def change
    create_table :buddy_relays do |t|
      t.references :from_user, null: false, foreign_key: { to_table: :users }
      t.references :to_user,   null: false, foreign_key: { to_table: :users }
      t.references :from_conversation, foreign_key: { to_table: :byte_conversations }
      t.references :to_conversation,   foreign_key: { to_table: :byte_conversations }
      t.references :to_byte_action,    foreign_key: { to_table: :byte_actions }

      t.integer :kind,   null: false, default: 0
      t.integer :status, null: false, default: 0
      t.text    :body,   null: false
      t.jsonb   :options, null: false, default: []
      t.jsonb   :answer

      t.datetime :delivered_at
      t.datetime :answered_at

      t.timestamps
    end

    # Recipient looks up its own still-open questions every turn (context) and
    # when recording an answer; keep that read cheap.
    add_index :buddy_relays, [:to_user_id, :status]
  end
end
