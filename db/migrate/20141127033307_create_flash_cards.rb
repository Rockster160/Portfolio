class CreateFlashCards < ActiveRecord::Migration
  def change
    create_table :flash_cards do |t|
      t.belongs_to :batch
      t.string :title
      t.text :body
      t.integer :pin

      t.timestamps
    end
  end
end
