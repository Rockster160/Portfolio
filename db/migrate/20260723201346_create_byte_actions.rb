class CreateByteActions < ActiveRecord::Migration[7.1]
  def change
    create_table :byte_actions do |t|
      # UUID minted by whoever originates the request (Mac hook, Jarvis
      # worker, etc). Same id travels through the whole lifecycle so all
      # sides — waiting hook, PWA button, decision webhook — can correlate.
      t.string :request_id, null: false
      # 0=permission (Bash/Write/Edit hook), 1=plan (ExitPlanMode),
      # 2=question (AskUserQuestion), 3=jarvis (Rails-side clarification),
      # 4=custom (open-ended, for future integrations).
      t.integer :kind, null: false, default: 0
      # 0=pending, 1=decided, 2=expired, 3=aborted.
      t.integer :state, null: false, default: 0
      t.references :user, null: false, foreign_key: true, index: true
      t.references :byte_conversation, null: false, foreign_key: true, index: true
      t.references :byte_message, null: true, foreign_key: true, index: true
      t.string :tool_name
      t.jsonb :tool_input, null: false, default: {}
      t.jsonb :buttons, null: false, default: []
      t.boolean :multi_select, null: false, default: false
      t.jsonb :decision, null: false, default: {}
      t.datetime :expires_at
      t.datetime :decided_at
      t.timestamps
    end

    add_index :byte_actions, :request_id, unique: true
    add_index :byte_actions, [:state, :expires_at]
  end
end
