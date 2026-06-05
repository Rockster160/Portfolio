class AddHotEligibilityToChores < ActiveRecord::Migration[7.1]
  def change
    # Integer enum (matches the rest of the table's discriminators).
    # 0 = always eligible (default — old behaviour)
    # 1 = only when scheduled today / overdue
    # 2 = never (exclude from hot-pick selection entirely)
    add_column :chores, :hot_eligibility, :integer, null: false, default: 0
  end
end
