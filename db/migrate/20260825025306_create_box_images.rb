class CreateBoxImages < ActiveRecord::Migration[7.1]
  def change
    create_table :box_images do |t|
      t.text :box_key, null: false
      t.bigint :user_id, null: false
      t.text :caption
      t.timestamps
    end

    add_index :box_images, :box_key
    add_index :box_images, :user_id
  end
end
