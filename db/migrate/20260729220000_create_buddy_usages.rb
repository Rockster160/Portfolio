class CreateBuddyUsages < ActiveRecord::Migration[7.1]
  # One row per model API call, so a turn that round-trips through get_context
  # produces several. Per-message cost is a SUM over byte_message_id; the rollup
  # is also denormalized onto the reply's metadata for display.
  #
  # byte_message_id is nullable on purpose: compaction runs its own call before a
  # turn's reply exists, and that cost is real and worth seeing separately.
  def change
    create_table :buddy_usages do |t|
      t.references :user, null: false, foreign_key: true
      t.references :byte_conversation, foreign_key: true
      t.references :byte_message, foreign_key: true

      # 0 = turn, 1 = compaction. See BuddyUsage.kinds.
      t.integer :kind, null: false, default: 0
      t.string :model, null: false

      # input_tokens INCLUDES cached_input_tokens (they bill at a ~90% discount).
      # output_tokens INCLUDES reasoning_tokens (billed at the output rate).
      t.integer :input_tokens, null: false, default: 0
      t.integer :cached_input_tokens, null: false, default: 0
      t.integer :output_tokens, null: false, default: 0
      t.integer :reasoning_tokens, null: false, default: 0

      # Integer micro-dollars (millionths of a dollar). Computed at call time
      # from the rates then in effect, so later price changes never rewrite
      # history. bigint because a year of summed rows outgrows int.
      t.bigint :cost_micros, null: false, default: 0

      t.timestamps
    end

    # "what did this cost me over that period", the query this table exists for.
    add_index :buddy_usages, [:user_id, :created_at]
  end
end
