class CreateBuddyMemories < ActiveRecord::Migration[7.1]
  def change
    create_table :buddy_memories do |t|
      t.references :user,     null: false, foreign_key: true
      t.text       :content,  null: false
      t.integer    :priority, null: false, default: 0
      t.jsonb      :tags,     null: false, default: []
      t.jsonb      :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :buddy_memories, [:user_id, :created_at]
  end
end
