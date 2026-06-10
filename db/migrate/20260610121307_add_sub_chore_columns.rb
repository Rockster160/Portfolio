class AddSubChoreColumns < ActiveRecord::Migration[7.1]
  # SubChore = a Chore whose `parent_chore_id` is set. Always one_off,
  # carries its own name / icon / due date, but its completions credit
  # the parent — recorded on `chore_completions.sub_chore_id` so the
  # tap-source stays visible without losing the parent's payout, hot
  # multiplier, streak, and cooldown semantics.
  def change
    add_reference :chores, :parent_chore,
                  foreign_key: { to_table: :chores },
                  null:        true,
                  index:       true
    add_reference :chore_completions, :sub_chore,
                  foreign_key: { to_table: :chores },
                  null:        true,
                  index:       true
  end
end
