class AddAnonymousToChoreCompletions < ActiveRecord::Migration[7.1]
  def change
    # An anonymous completion records that the chore was DONE (so the
    # schedule and cooldown advance) without crediting any household
    # member — used for cases like a neighbor bringing in the trash
    # cans. user_id still tracks who RECORDED it, for auditing.
    add_column :chore_completions, :anonymous, :boolean, null: false, default: false
  end
end
