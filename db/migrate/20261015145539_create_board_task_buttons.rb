class CreateBoardTaskButtons < ActiveRecord::Migration[7.1]
  def change
    create_table :board_task_buttons do |t|
      t.references :user, null: false, foreign_key: true
      t.references :task, null: false, foreign_key: true
      t.text :label, null: false
      t.text :icon
      t.text :color
      t.text :tags, array: true, null: false, default: []
      t.integer :sort_order

      t.timestamps
    end
  end
end
