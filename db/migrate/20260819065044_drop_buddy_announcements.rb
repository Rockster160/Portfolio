class DropBuddyAnnouncements < ActiveRecord::Migration[7.1]
  # Announcements are gone. Three briefings in a row read the queued note out of
  # the seed and simply didn't say it, and the last attempt at making them say
  # it cost a briefing entirely — so the feature is out rather than left in
  # half-working. `20260819042151` already ran in production, which is why this
  # is a drop rather than that file being deleted.
  def change
    drop_table(:buddy_announcements) { |t|
      t.references(:user, null: false, foreign_key: true)
      t.text(:body, null: false)
      t.datetime(:delivered_at)
      t.datetime(:expires_at)

      t.timestamps

      t.index([:user_id, :delivered_at])
    }
  end
end
