class CreateBuddyAnnouncements < ActiveRecord::Migration[7.1]
  # A note to be worked into somebody's NEXT Today briefing, in their
  # companion's own words.
  #
  # One row per person even when the same thing goes to the whole household:
  # they read their briefings at different times and one of them may never read
  # the next one at all, so delivery has to be tracked per person or a shared
  # row gets marked done by whoever got up first.
  def change
    create_table(:buddy_announcements) do |t|
      t.references(:user, null: false, foreign_key: true)
      t.text(:body, null: false)

      # Stamped when the briefing that carried it was built. Kept rather than
      # deleted so a briefing that failed to send can be re-queued from the
      # admin page instead of the announcement simply being gone.
      t.datetime(:delivered_at)

      # Past this, it stops being worth saying. An announcement about tonight is
      # noise on Thursday, and nothing else in the system would ever clear it.
      t.datetime(:expires_at)

      t.timestamps
    end

    # The lookup every briefing does: this person's undelivered, unexpired ones.
    add_index(:buddy_announcements, [:user_id, :delivered_at])
  end
end
