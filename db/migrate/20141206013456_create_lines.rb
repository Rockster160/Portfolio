class CreateLines < ActiveRecord::Migration
  def change
    create_table :lines do |t|
      t.belongs_to :flash_card
      t.string :text
      t.boolean :center

      t.timestamps
    end
  end
end
