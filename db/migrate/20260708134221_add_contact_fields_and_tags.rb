class AddContactFieldsAndTags < ActiveRecord::Migration[7.1]
  def change
    add_column :contacts, :email, :text
    add_column :contacts, :birthday, :date
    add_column :contacts, :notes, :text

    create_table :contact_tags do |t|
      t.references :contact, null: false, foreign_key: true
      t.references :tag, null: false, foreign_key: true
      t.timestamps
    end
  end
end
