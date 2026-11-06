# A user can keep several quest boards, one per game, each named. A board
# that already exists becomes "Quests"; new ones are always given a name.
class AddNameToQuestBoards < ActiveRecord::Migration[7.1]
  def change
    add_column :quest_boards, :name, :string, null: false, default: "Quests"
    change_column_default :quest_boards, :name, from: "Quests", to: nil
    remove_index :quest_boards, :user_id, unique: true
    add_index :quest_boards, :user_id
  end
end
