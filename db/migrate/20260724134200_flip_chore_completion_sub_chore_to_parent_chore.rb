class FlipChoreCompletionSubChoreToParentChore < ActiveRecord::Migration[7.1]
  # Before: chore_completions.chore_id = credited parent, sub_chore_id = tapped leaf.
  # After:  chore_completions.chore_id = tapped leaf, parent_chore_id = credited parent.
  # Sub-chore completions now share the same shape as any other completion —
  # chore_id is the ACTUAL chore that was tapped. Parent lookup rides on the
  # denormalized parent_chore_id column so aggregations (parent card's
  # "done today across sub-chores") stay one WHERE away.
  def up
    add_reference :chore_completions, :parent_chore,
                  foreign_key: { to_table: :chores },
                  null:        true,
                  index:       true

    execute(<<~SQL)
      UPDATE chore_completions
      SET parent_chore_id = chore_id,
          chore_id = sub_chore_id
      WHERE sub_chore_id IS NOT NULL
    SQL

    remove_reference :chore_completions, :sub_chore, foreign_key: { to_table: :chores }, index: true
  end

  def down
    add_reference :chore_completions, :sub_chore,
                  foreign_key: { to_table: :chores },
                  null:        true,
                  index:       true

    execute(<<~SQL)
      UPDATE chore_completions
      SET sub_chore_id = chore_id,
          chore_id = parent_chore_id
      WHERE parent_chore_id IS NOT NULL
    SQL

    remove_reference :chore_completions, :parent_chore, foreign_key: { to_table: :chores }, index: true
  end
end
