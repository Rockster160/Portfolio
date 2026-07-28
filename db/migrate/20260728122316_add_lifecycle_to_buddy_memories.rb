class AddLifecycleToBuddyMemories < ActiveRecord::Migration[7.1]
  def change
    # Short-term memories expire and get pruned; durable facts leave this null.
    add_column :buddy_memories, :expires_at, :datetime
    # Bumped whenever a fact is reinforced (re-mentioned). Lets us see which
    # memories have gone cold for curation — NOT for auto-deleting durable facts.
    add_column :buddy_memories, :last_used_at, :datetime

    add_index :buddy_memories, [:user_id, :expires_at]
  end
end
