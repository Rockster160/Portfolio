class MoveBuddyTimerPagesOffBuddySlug < ActiveRecord::Migration[7.1]
  # Buddy's timer page moves to a slug no page name turns into, which frees
  # "buddy" for a page of the person's own. Its finished timers are archived
  # on the way: nothing shows them, and they had piled up unarchived.
  def up
    execute(
      <<~SQL.squish,
        UPDATE timer_pages SET slug = '__buddy', updated_at = NOW()
        WHERE slug = 'buddy' AND meta->>'buddy' = 'true'
      SQL
    )
    execute(
      <<~SQL.squish,
        UPDATE timers SET archived_at = NOW(), updated_at = NOW()
        WHERE archived_at IS NULL AND started_at IS NULL AND paused_at IS NULL
          AND timer_page_id IN (SELECT id FROM timer_pages WHERE slug = '__buddy')
      SQL
    )
  end

  # The slug goes back; archived timers stay archived.
  def down
    execute(
      <<~SQL.squish,
        UPDATE timer_pages SET slug = 'buddy', updated_at = NOW()
        WHERE slug = '__buddy'
      SQL
    )
  end
end
