class CreateBuddyRoutines < ActiveRecord::Migration[7.1]
  # A named, saved sequence of Buddy tool calls - "prep my printer" is power the
  # printer on, wait a minute, then preheat. `steps` holds the calls verbatim
  # ([{ tool_name:, payload: }, ...]) and replays through ProposalBuilder, which
  # already knows how to order them and hold the tail behind a wait.
  def change
    create_table :buddy_routines do |t|
      t.references :user, null: false, foreign_key: true

      # What they say to run it, and one line on what it does.
      t.string :name, null: false
      t.string :description

      # The markers themselves: [{ tool_name:, payload: }, ...] in run order.
      t.jsonb :steps, null: false, default: []

      t.boolean :enabled, null: false, default: true
      t.integer :run_count, null: false, default: 0
      t.datetime :last_run_at
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    # Names are how the person and the model both refer to a routine, so two
    # with the same name would make "run prep my printer" ambiguous. Case
    # -insensitive because "Prep Printer" and "prep printer" are one routine.
    add_index :buddy_routines, "user_id, lower(name)", unique: true, name: "index_buddy_routines_on_user_and_name"
  end
end
