class AddEmailAttachments < ActiveRecord::Migration[5.0]
  def change
    add_column :emails, :attachments, :text
  end
end
