class AddHouseholdScopeToChoreAchievements < ActiveRecord::Migration[7.1]
  def change
    add_reference :chore_achievements,
      :created_by_user,
      foreign_key: { to_table: :users },
      null: true
  end
end
