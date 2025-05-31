class RecreateEmails < ActiveRecord::Migration[7.1]
  def change
    add_index :active_storage_attachments, :blob_id, name: "index_active_storage_attachments_on_blob_id"

    drop_table :emails, if_exists: true
    create_table :emails do |t|
      t.belongs_to :user, null: false, foreign_key: true

      t.integer :direction, null: false # 0: inbound, 1: outbound

      t.jsonb :inbound_mailboxes, null: false, default: []
      t.jsonb :outbound_mailboxes, null: false, default: []
      t.text :subject, null: false
      t.text :blurb, null: false
      t.boolean :has_attachments, default: false, null: false

      t.datetime :timestamp, null: false
      t.datetime :read_at
      t.datetime :archived_at

      t.timestamps
    end
  end
end
