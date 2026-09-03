class CreateJobApplications < ActiveRecord::Migration[7.1]
  def change
    create_table :job_applications do |t|
      t.references :user, null: false, foreign_key: true

      t.string :company, null: false
      t.string :role
      # active / offer / rejected / closed. The index hides the dead ones by
      # default, which is the only reason this isn't a boolean.
      t.integer :status, null: false, default: 0
      # Random at creation. Carried onto every follow-up this job puts on the
      # calendar, so a week of interviews reads by colour without squinting.
      t.string :color, null: false
      # Square data:image/* URL, same shape and size ceiling as HouseholdIcon.
      t.text :logo_data

      # Where the listing came from, and the listing itself. Set with the
      # initial application; notes carry their own optional pair.
      t.string :source
      t.string :url

      # Newest note's timestamp, so the index sorts by what actually moved
      # rather than by when the row happened to be typed in.
      t.datetime :last_activity_at

      t.timestamps
    end

    add_index :job_applications, %i[user_id status]
    add_index :job_applications, %i[user_id last_activity_at]
  end
end
