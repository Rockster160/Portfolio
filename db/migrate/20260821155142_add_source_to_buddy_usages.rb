class AddSourceToBuddyUsages < ActiveRecord::Migration[7.1]
  def change
    # Existing rows default to `production`, in every environment, on purpose.
    # Development here is a restore of a production backup, so most of what is
    # already in it was spent by production and is already counted there —
    # stamping the lot `development` would hand it all back a second time.
    # Anything genuinely local from before this migration is picked out by
    # lib/scripts/mark_local_buddy_usages.rb, which knows where the restore
    # ends. From here on the environment is stamped when the row is written.
    add_column :buddy_usages, :env, :integer, default: 0, null: false
    add_column :buddy_usages, :origin_uid, :string

    add_index :buddy_usages, :origin_uid, unique: true
    add_index :buddy_usages, [:env, :created_at]
  end
end
