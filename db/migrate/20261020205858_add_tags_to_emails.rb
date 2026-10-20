class AddTagsToEmails < ActiveRecord::Migration[7.1]
  def change
    add_column :emails, :tags, :text, array: true, default: [], null: false
    add_index :emails, :tags, using: :gin
  end
end
