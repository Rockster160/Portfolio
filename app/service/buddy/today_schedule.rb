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

    def briefing?(reminder)
      reminder.metadata.is_a?(Hash) && reminder.metadata["today_briefing"].present?
    end

    # `at` is the LATEST the briefing may land, not the time it always lands.
    #
    # Moving the schedule onto a reminder took `at` literally, and a flat 08:30
    # is wrong on exactly the mornings a briefing matters: on 19 Aug it went out
    # at 08:30:40 against a Focus block that started at 08:30:00, in the same
    # second. Chelsea only escaped it because her first thing was 11:30 - the
    # day before she had 9:25 yoga with a half-hour drive, and 08:30 would have
    # briefed her five minutes after she needed to be in the car.
    #
    # So the old rule comes back: thirty minutes before DEPARTURE for the first
    # thing that starts before the cutoff, which is the start minus the known
    # drive minus the half hour. Never later than `at` - this only pulls
    # forward, and a day with nothing early keeps the time they chose.
    #
    # Applied when the occurrence is SET (created, and rolled forward after each
    # fire) rather than swept for, so there's no new job. The gap that leaves is
    # an early item added to tomorrow after this morning's briefing has already
    # rolled the clock - it briefs at `at` on that day. Worth knowing before
    # reaching for a sweep to close it: it costs a job running all day to catch
    # a case that a calendar synced ahead of time mostly doesn't produce.
    LEAD      = 30.minutes
    CUTOFF_HR = 10

    def fire_time(user, at)
      return at if at.nil?

      first = first_event_before_cutoff(user, at)
      return at if first.nil?

      [first.start_at - drive_minutes(first).minutes - LEAD, at].min
    rescue StandardError => e
      Buddy::Errors.report(section: "today_schedule.fire_time", exception: e, user: user)
      at
    end

    # The perceived day's earliest OWNED, non-cancelled, timed event before the
    # cutoff - nil if none. Perceived-day bounded (3am rollover) so this agrees
    # with the rest of Buddy about which day it is.
    def first_event_before_cutoff(user, now)
      agenda_ids = Agenda.where(user_id: user.id).pluck(:id)
      return nil if agenda_ids.empty?

      day_start, = Buddy::Day.range(user, now: now)
      cutoff     = Buddy::Day.at(user, hour: CUTOFF_HR, now: now)

      scope = AgendaItem.where(agenda_id: agenda_ids).where.not(status: :cancelled)
      scope.where(all_day: [false, nil]).where(start_at: day_start.utc...cutoff.utc).order(:start_at).first
    end

    # Known drive time (minutes) from the travel-chain sync on the item's
    # metadata; 0 when there's none.
    def drive_minutes(item)
      travel = item.metadata.is_a?(Hash) ? item.metadata["travel"] : nil
      mins   = travel.is_a?(Hash) ? travel["travel_minutes"].to_i : 0
      mins.positive? ? mins : 0
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
      reminder.fire_at = fire_time(user, reminder.next_fire_at(from: Time.current))
      reminder.save!
      reminder
    end
  end
end
