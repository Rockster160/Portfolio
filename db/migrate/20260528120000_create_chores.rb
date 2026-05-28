class CreateChores < ActiveRecord::Migration[7.1]
  def change
    create_table :chores do |t|
      t.references :created_by_user, null: false, foreign_key: { to_table: :users }
      t.text :name, null: false
      t.text :short_name
      t.text :icon
      t.jsonb :aliases, null: false, default: []
      t.integer :reward_pebbles, null: false, default: 0
      t.integer :threshold_seconds
      t.jsonb :recurrence
      t.date :starts_on
      t.boolean :one_off, null: false, default: false
      t.datetime :archived_at
      t.integer :sort_order
      t.timestamps
    end

    add_index :chores, :archived_at
    add_index :chores, :one_off
    add_index :chores, :reward_pebbles

    create_table :chore_completions do |t|
      t.references :chore, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.datetime :completed_at, null: false
      t.date :day_key, null: false
      t.integer :paid_pebbles, null: false, default: 0
      t.integer :base_pebbles, null: false, default: 0
      t.float :hot_multiplier, null: false, default: 1.0
      t.float :total_multiplier, null: false, default: 1.0
      t.integer :achievement_bonus_pebbles, null: false, default: 0
      t.boolean :payout_skipped, null: false, default: false
      t.text :skipped_reason
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :chore_completions, [:user_id, :completed_at]
    add_index :chore_completions, [:chore_id, :user_id, :day_key]
    add_index :chore_completions, [:user_id, :day_key]

    create_table :chore_shares do |t|
      t.references :user, null: false, foreign_key: true
      t.references :shared_with_user, null: false, foreign_key: { to_table: :users }
      t.integer :permission, null: false, default: 1
      t.timestamps
    end

    add_index :chore_shares, [:user_id, :shared_with_user_id], unique: true, name: :index_chore_shares_pair

    create_table :chore_goals do |t|
      t.references :user, null: false, foreign_key: true
      t.string :name, null: false
      t.text :image_url
      t.text :link_url
      t.integer :cost_pebbles, null: false, default: 0
      t.datetime :achieved_at
      t.datetime :archived_at
      t.integer :sort_order
      t.timestamps
    end

    add_index :chore_goals, [:user_id, :archived_at]

    create_table :chore_achievements do |t|
      t.string :name, null: false
      t.text :description
      t.integer :kind, null: false, default: 0
      t.jsonb :config, null: false, default: {}
      t.integer :reward_pebbles, null: false, default: 0
      t.text :reward_link
      t.text :image_url
      t.boolean :active, null: false, default: true
      t.timestamps
    end

    create_table :user_chore_achievements do |t|
      t.references :user, null: false, foreign_key: true
      t.references :chore_achievement, null: false, foreign_key: true
      t.datetime :earned_at, null: false
      t.integer :awarded_pebbles, null: false, default: 0
      t.references :chore_completion, foreign_key: true
      t.timestamps
    end

    add_index :user_chore_achievements,
              [:user_id, :chore_achievement_id],
              unique: true,
              name: :index_user_chore_achievements_pair

    create_table :chore_multipliers do |t|
      t.references :user, null: false, foreign_key: true
      t.string :name, null: false
      t.integer :kind, null: false, default: 0
      t.jsonb :config, null: false, default: {}
      t.boolean :active, null: false, default: true
      t.integer :sort_order
      t.timestamps
    end

    create_table :chore_withdrawals do |t|
      t.references :user, null: false, foreign_key: true
      t.integer :amount_pebbles, null: false
      t.text :note
      t.timestamps
    end

    add_index :chore_withdrawals, [:user_id, :created_at]

    create_table :chore_hot_picks do |t|
      t.date :day_key, null: false
      t.references :chore, null: false, foreign_key: true
      t.float :multiplier, null: false, default: 2.0
      t.timestamps
    end

    add_index :chore_hot_picks, [:day_key, :chore_id], unique: true

    create_table :chore_streaks do |t|
      t.references :user, null: false, foreign_key: true
      t.references :chore, null: false, foreign_key: true
      t.integer :current_streak, null: false, default: 0
      t.integer :longest_streak, null: false, default: 0
      t.date :last_completed_day
      t.timestamps
    end

    add_index :chore_streaks, [:user_id, :chore_id], unique: true
  end
end
