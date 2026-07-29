class CreateBuddyIdeas < ActiveRecord::Migration[7.1]
  def change
    create_table :buddy_ideas do |t|
      t.references :user, null: false, foreign_key: true
      # nil until categorized (an "anything" dump Buddy hasn't sorted yet).
      t.integer :category
      t.text :body, null: false
      t.text :summary
      t.integer :status, null: false, default: 0
      t.datetime :surfaced_at  # last time Buddy brought it up
      t.datetime :remind_after # "bring it up later" defer point

      t.timestamps
    end

    add_index :buddy_ideas, [:user_id, :status]
  end
end
