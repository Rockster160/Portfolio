class CreateChoreCreditButtons < ActiveRecord::Migration[7.1]
  def change
    create_table :chore_credit_buttons do |t|
      # Household-scoped like chores, so a shared board's buttons show for
      # everyone in the house, not just whoever made them.
      t.references :chore_household, null: false, foreign_key: true
      t.references :created_by_user, null: false, foreign_key: { to_table: :users }
      # The chore a press completes, and the member it credits.
      t.references :chore, null: false, foreign_key: true
      t.references :credit_user, null: false, foreign_key: { to_table: :users }
      # Which board group it belongs to, its words, and its colour.
      t.text    :tag
      t.text    :label, null: false
      t.text    :color
      t.integer :sort_order

      t.timestamps
    end

    add_index :chore_credit_buttons, [:chore_household_id, :tag]
  end
end
