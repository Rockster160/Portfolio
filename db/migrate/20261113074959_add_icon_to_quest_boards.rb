class AddIconToQuestBoards < ActiveRecord::Migration[7.1]
  def change
    change_table(:quest_boards, bulk: true) { |t|
      t.string :icon
      t.string :icon_color
      t.binary :icon_png
    }
  end
end
