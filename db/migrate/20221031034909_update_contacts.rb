class UpdateContacts < ActiveRecord::Migration[7.0]
  def change
    change_table :contacts do |t|
      t.column :nickname, :text
      t.column :raw, :jsonb
      t.column :apple_contact_id, :text
    end
  end
end
