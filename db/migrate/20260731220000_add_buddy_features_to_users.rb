class AddBuddyFeaturesToUsers < ActiveRecord::Migration[7.1]
  # Which parts of Buddy a person HAS (see Buddy::Features). An allow-list, so a
  # feature added later is off for everyone until it's deliberately granted.
  # New accounts are handed the default set at creation by User, which keeps
  # "fail closed on new features" from also meaning "fail closed on new people".
  #
  # Written out here rather than read from Buddy::Features so the backfill still
  # describes what it did if the constant changes later.
  DEFAULT = %w[chores agenda lists events jil relay prompts].freeze

  def up
    add_column :users, :buddy_features, :jsonb, default: [], null: false

    # Everyone starts with the default set...
    User.reset_column_information
    User.update_all(buddy_features: DEFAULT)
    # ...the owner of the Mac also gets to drive it...
    User.where(id: 1).update_all(buddy_features: DEFAULT + ["mac"])
    # ...and Eve has no chores, completions, or pebbles.
    User.where(id: 4).update_all(buddy_features: DEFAULT - ["chores"])
  end

  def down
    remove_column :users, :buddy_features
  end
end
