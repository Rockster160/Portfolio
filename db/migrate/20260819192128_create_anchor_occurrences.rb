class CreateAnchorOccurrences < ActiveRecord::Migration[7.1]
  def change
    create_table :anchor_occurrences do |t|
      t.references :anchor, null: false, foreign_key: true
      t.datetime :occurs_at, null: false
      # Caller-supplied name for THIS occurrence ("2026-08-19"). Writing the
      # same identifier again updates that timestamp instead of adding another,
      # which is what lets an hourly refresh re-state the same days idempotently.
      # NULL means "just append one" - Postgres treats NULLs as distinct, so any
      # number of un-identified occurrences can coexist.
      t.text :identifier

      t.timestamps
    end

    add_index :anchor_occurrences, [:anchor_id, :identifier], unique: true
    add_index :anchor_occurrences, [:anchor_id, :occurs_at]
  end
end
