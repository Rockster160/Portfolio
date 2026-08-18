module Buddy
  # When the morning briefing goes out, and whether it goes out at all.
  #
  # It used to be a hardcoded 8:30 inside Buddy::TodayScheduler, on an
  # every-minute cron - which made the one message Buddy sends unprompted every
  # day the only thing about Buddy nobody could change. It's now an ordinary
  # recurring BuddyReminder carrying the `today_briefing` tool as its `action`.
  #
  # That's the whole design, and the reason there is no new machinery: a
  # reminder already knows how to repeat, how to be moved, and how to be
  # cancelled. `move_reminder` changes the hour, `cancel_reminder` stops it, the
  # reminders panel lists it, and `upcoming_reminders` puts it in front of Buddy
  # so it can answer when the next one is due.
  #
  # WHAT the briefing says stays in Rails (Buddy::TodayBriefing owns the
  # prompt). This is only about when, and whether.
  module TodaySchedule
    module_function

    DEFAULT = "08:30".freeze
    # What the person sees on the row in the reminders panel. Never parsed —
    # `metadata.today_briefing` is what identifies it, since a body is something
    # they can edit.
    BODY    = "Today briefing".freeze
    TOOL    = :today_briefing

    # Every Today reminder this user has ever had, cancelled ones included.
    #
    # `ensure!` asks about ALL of them and `scheduled?` asks only about the live
    # one, and the difference is the point: a cancelled row still answers "have
    # they already been set up", so calling ensure! again can't hand back the
    # thing they switched off.
    def all_for(user)
      BuddyReminder.where(user_id: user.id)
        .where("buddy_reminders.metadata ->> 'today_briefing' = 'true'")
        .order(:id)
    end

    def for(user)
      all_for(user).merge(BuddyReminder.pending).first
    end

    def scheduled?(user)
      self.for(user).present?
    end

    # The reminder, made if one has never been made. Idempotent, and
    # deliberately does NOT reinstate a cancelled one - that's "stop sending me
    # this", and it has to survive the next time anything calls this, or
    # cancelling becomes a thing that undoes itself overnight.
    def ensure!(user, at: DEFAULT)
      all_for(user).first || create!(user, at: at)
    end

    def create!(user, at: DEFAULT)
      # Their own thread, never the wall tablet. Decided once, here, rather than
      # at every fire: the briefing is addressed to one person, and on a kiosk it
      # would be read by whoever walked into the kitchen while the person it was
      # written for got nothing.
      conversation = ByteConversation.for_self_initiated(user)
      raise "no conversation to brief #{user.username} in" if conversation.nil?

      clock    = at.to_s.match?(/\A\d{1,2}:\d{2}\z/) ? at.to_s : DEFAULT
      reminder = BuddyReminder.new(
        user:              user,
        byte_conversation: conversation,
        body:              BODY,
        recurrence:        { "freq" => "daily", "at" => clock },
        # The tool NAME, never a resolved id - re-resolved every time it fires,
        # the same way a scheduled function is.
        action:            { "tool" => TOOL.to_s, "payload" => {} },
        metadata:          { "today_briefing" => true },
      )
      reminder.fire_at = reminder.next_fire_at(from: Time.current)
      reminder.save!
      reminder
    end
  end
end
