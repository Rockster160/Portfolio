class CreateBuddyAlerts < ActiveRecord::Migration[7.1]
  def change
    create_table :buddy_alerts do |t|
      t.references :user, null: false, foreign_key: true
      t.references :byte_conversation, null: false, foreign_key: true
      t.references :byte_message, null: true, foreign_key: true
      t.text :key, null: false
      t.integer :status, null: false, default: 0
      t.text :body, null: false
      t.text :resolution
      t.integer :raised_count, null: false, default: 1
      t.datetime :raised_at, null: false
      t.datetime :last_raised_at, null: false
      t.datetime :resolved_at
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    # One open alert per key, enforced in the database rather than in the
    # service: the raise is called from a Jil trigger, two of which can land in
    # the same second (a sensor that bounces), and a second row for a key means
    # a second bubble that nothing will ever resolve.
    add_index :buddy_alerts, [:user_id, :key], unique: true, where: "status = 0",
      name: "index_buddy_alerts_on_one_open_per_key"
    add_index :buddy_alerts, [:user_id, :status, :last_raised_at]
  end
end
