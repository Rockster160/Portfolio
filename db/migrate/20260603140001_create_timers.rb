class CreateTimers < ActiveRecord::Migration[7.1]
  def change
    create_table :timers do |t|
      t.references :user,       null: false, foreign_key: true, index: true
      t.references :timer_page, null: true,  foreign_key: true, index: true

      t.text    :name, null: false, default: ""
      t.integer :kind, null: false, default: 0
      t.text    :color
      t.integer :section_id
      t.integer :pos_x,  null: false, default: 0
      t.integer :pos_y,  null: false, default: 0
      t.integer :width,  null: false, default: 0
      t.integer :height, null: false, default: 0

      # Countdown
      t.bigint   :duration_ms
      t.datetime :started_at, precision: 6
      t.datetime :paused_at,  precision: 6
      t.bigint   :paused_remaining_ms
      t.datetime :end_at, precision: 6
      t.boolean  :repeat,              null: false, default: false
      t.integer  :repeat_count,        null: false, default: 0
      t.boolean  :require_confirm_tap, null: false, default: false

      # Counter
      t.integer :value,       null: false, default: 0
      t.integer :step,        null: false, default: 1
      t.integer :min_value
      t.integer :max_value
      t.integer :reset_value, null: false, default: 0

      # Dial
      t.jsonb   :dial_config,     null: false, default: {}
      t.integer :dial_step_index, null: false, default: 0

      # Callbacks
      t.jsonb :callbacks, null: false, default: []

      # Sidekiq hook
      t.string   :fire_jid
      t.datetime :fire_scheduled_for, precision: 6
      t.datetime :fired_at,           precision: 6
      t.datetime :confirmed_at,       precision: 6

      t.datetime :archived_at, precision: 6
      t.timestamps precision: 6
    end

    add_index :timers, [:user_id, :kind, :archived_at]
    add_index :timers, :end_at, where: "end_at IS NOT NULL AND fired_at IS NULL", name: :index_timers_pending_fire
    add_index :timers, :fire_jid, unique: true, where: "fire_jid IS NOT NULL"
  end
end
