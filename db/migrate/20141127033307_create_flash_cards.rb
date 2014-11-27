class CreateFlashCards < ActiveRecord::Migration
  def change
    create_table :flash_cards do |t|
      t.string :title
      t.string :line, :array => true, default: [["",0],["",0],["",0],["",0],["",0],["",0],["",0],["",0]]
      t.text :body
      t.integer :pin

      t.timestamps
    end
  end
end
