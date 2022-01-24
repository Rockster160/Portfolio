class CreateBowlingFrame < ActiveRecord::Migration[5.0]
  def change
    create_table :bowling_frames do |t|
      t.belongs_to :bowling_game
      t.integer :frame_num
      t.integer :throw1
      t.integer :throw2
      t.integer :throw3
      t.string :throw1_remaining
      t.string :throw2_remaining
      t.string :throw3_remaining
      t.boolean :spare, default: false
      t.boolean :strike, default: false
      t.boolean :split, default: false

      t.timestamps
    end
  end
end
