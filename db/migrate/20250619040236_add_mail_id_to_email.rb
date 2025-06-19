class AddMailIdToEmail < ActiveRecord::Migration[7.1]
  def change
    add_column :emails, :mail_id, :text
  end
end
