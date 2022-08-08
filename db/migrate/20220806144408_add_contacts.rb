class AddContacts < ActiveRecord::Migration[7.0]
  def change
    create_table :contacts do |t|
      t.belongs_to :user
      t.text :name
      t.text :address
      t.text :phone
      t.float :lat
      t.float :lng

      t.timestamps
    end
  end
end
