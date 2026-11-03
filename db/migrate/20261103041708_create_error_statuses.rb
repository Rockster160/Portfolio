class CreateErrorStatuses < ActiveRecord::Migration[7.1]
  def change
    create_table :error_statuses do |t|
      t.text :fingerprint, null: false
      t.integer :status, null: false
      t.references :user
      t.timestamps
    end
    add_index :error_statuses, :fingerprint, unique: true
  end
end
