class CreateBuddyCommands < ActiveRecord::Migration[7.1]
  def change
    create_table(:buddy_commands) { |t|
      t.references :user, null: false, foreign_key: true
      t.string :name, null: false
      t.jsonb :steps, null: false, default: []
      t.text :say
      t.integer :run_count, null: false, default: 0
      t.datetime :last_run_at

      t.timestamps
    }

    add_index :buddy_commands, "user_id, LOWER(name)", unique: true, name: :index_buddy_commands_on_user_and_name
  end
end
