class CreateAppDevices < ActiveRecord::Migration[7.1]
  def change
    create_table :app_devices do |t|
      t.references :user, null: false, foreign_key: true
      t.text :app, null: false, default: "buddy"
      t.text :name
      t.text :token_digest, null: false
      t.text :platform
      t.text :model
      t.text :os_version
      t.text :app_version
      t.text :timezone
      t.text :apns_token
      t.text :apns_environment
      t.jsonb :push_to_start_tokens, null: false, default: {}
      t.text :widget_push_token
      t.jsonb :features, null: false, default: []
      t.jsonb :preferences, null: false, default: {}
      t.datetime :last_seen_at
      t.datetime :revoked_at

      t.timestamps
    end
    add_index :app_devices, :token_digest, unique: true
    add_index :app_devices, :apns_token

    create_table :app_device_submissions do |t|
      t.references :app_device, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.text :uuid, null: false
      t.text :kind, null: false
      t.text :key
      t.text :text
      t.jsonb :data, null: false, default: {}
      t.datetime :pressed_at
      t.text :source
      t.text :status, null: false, default: "received"
      t.text :response
      t.bigint :message_id
      t.text :error
      t.datetime :processed_at

      t.timestamps
    end
    add_index :app_device_submissions, :uuid, unique: true
    add_index :app_device_submissions, [:user_id, :kind, :created_at]

    create_table :app_live_activities do |t|
      t.references :app_device, null: false, foreign_key: true
      t.text :activity_id, null: false
      t.text :kind, null: false, default: "timer"
      t.text :ref_id
      t.text :push_token
      t.datetime :ended_at

      t.timestamps
    end
    add_index :app_live_activities, :activity_id, unique: true
    add_index :app_live_activities, [:kind, :ref_id]

    create_table :app_panels do |t|
      t.references :user, null: false, foreign_key: true
      t.text :key, null: false
      t.jsonb :content, null: false, default: {}

      t.timestamps
    end
    add_index :app_panels, [:user_id, :key], unique: true
  end
end
