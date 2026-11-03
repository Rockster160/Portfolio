# One row per tool call that changed something, wherever it ran from: a chat
# turn, a checklist tap, a form, a routine. Lookups are not recorded. The rows
# are what the activity page reads, and the ones carrying `reverts` can be
# undone from there.
class CreateBuddyActivities < ActiveRecord::Migration[7.1]
  def change
    create_table(:buddy_activities) { |t|
      t.references :user, null: false, foreign_key: true
      t.references :byte_conversation, foreign_key: { on_delete: :nullify }
      t.text :tool_name, null: false
      t.jsonb :payload, null: false, default: {}
      t.boolean :ok, null: false, default: true
      t.text :error_message
      # What the tool said it did, as the chat row shows it.
      t.text :receipt
      # Buddy::Reverter descriptors; empty when the call can't be walked back.
      t.jsonb :reverts, null: false, default: []
      t.datetime :undone_at
      t.text :undo_note

      t.timestamps
    }

    add_index :buddy_activities, [:user_id, :created_at]
  end
end
