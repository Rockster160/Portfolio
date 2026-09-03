class CreateJobNotes < ActiveRecord::Migration[7.1]
  def change
    create_table :job_notes do |t|
      t.references :job_application, null: false, foreign_key: true

      t.text :body, null: false
      # What kind of thing happened. Everything defaults to a plain note; the
      # rest are the beats of an application, and `rejected` closes the job.
      t.integer :tag, null: false, default: 0
      # When it HAPPENED, which is not when it was typed. Defaults to now.
      t.datetime :occurred_at, null: false

      t.string :source
      t.string :url
      t.string :spoke_to
      t.integer :duration_minutes

      # Optional "chase this on the 14th". Materialized as an agenda task so
      # the existing notification path does the reminding.
      t.datetime :follow_up_at
      t.bigint :agenda_item_id

      t.timestamps
    end

    add_index :job_notes, %i[job_application_id occurred_at]
    add_index :job_notes, :agenda_item_id
  end
end
