class CreateJilTrigger < ActiveRecord::Migration[7.1]
  def change
    rename_column :emails, :attachments, :legacy_attachment_json
    rename_column :emails, :blob, :legacy_blob

    add_column :emails, :blurb, :text

    add_index :active_storage_attachments, :blob_id, name: "index_active_storage_attachments_on_blob_id"
  end
end
