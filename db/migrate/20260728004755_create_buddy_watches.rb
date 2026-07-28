class CreateBuddyWatches < ActiveRecord::Migration[7.1]
  def change
    create_table :buddy_watches do |t|
      t.references :user,              null: false, foreign_key: true
      t.references :byte_conversation, null: false, foreign_key: true

      t.text    :body,          null: false
      t.string  :kind,          null: false, default: "prompt"
      t.string  :trigger_scope, null: false
      t.jsonb   :match,         null: false, default: {}
      t.boolean :one_shot,      null: false, default: true

      t.datetime :fired_at
      t.datetime :last_fired_at
      t.datetime :cancelled_at
      t.datetime :expires_at

      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    # WatchMatcher looks up active watches by (user, scope) on every
    # watchable trigger, so this index carries the hot path.
    add_index :buddy_watches, %i[user_id trigger_scope]
  end
end
