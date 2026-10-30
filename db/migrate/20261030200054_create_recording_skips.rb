class CreateRecordingSkips < ActiveRecord::Migration[7.1]
  def change
    create_table :recording_skips do |t|
      t.references :user, null: false, foreign_key: true
      t.string :key, null: false
      t.string :label
      t.timestamps
    end

    add_index :recording_skips, [:user_id, :key], unique: true
  end
end
