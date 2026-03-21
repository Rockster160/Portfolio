class CreateSharedPages < ActiveRecord::Migration[7.1]
  def change
    create_table :shared_pages do |t|
      t.references :page, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true

      t.timestamps
    end
    add_index :shared_pages, [:page_id, :user_id], unique: true
  end
end
