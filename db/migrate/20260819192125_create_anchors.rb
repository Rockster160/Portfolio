class CreateAnchors < ActiveRecord::Migration[7.1]
  def change
    create_table :anchors do |t|
      t.references :user, null: false, foreign_key: true
      t.text :key, null: false
      t.text :description

      t.timestamps
    end

    # The anchor exists independently of whether it currently has any
    # occurrences left, so a cron referencing one stays valid after its
    # timestamps have all been consumed.
    add_index :anchors, [:user_id, :key], unique: true
  end
end
