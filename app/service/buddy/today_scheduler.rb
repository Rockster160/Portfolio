module Buddy
  # Fires the scheduled morning "Today" briefing. Runs every minute (via
  # BuddyTodayWorker) and, for each Buddy user, delivers once per day at:
  #   * 30 minutes before their first event that starts before 10am, or
  #   * 8:30am local if they have no such event.
  # A 30-minute catch-up window covers a late/backed-up Sidekiq without firing
  # at a random hour, and a same-day "already delivered" check prevents repeats.
  module TodayScheduler
    module_function

    WINDOW    = 30.minutes
    FALLBACK  = { hour: 8, min: 30 }.freeze
    CUTOFF_HR = 10 # "first event before 10am"

    def run!(now: Time.current)
      candidate_users.find_each do |user|
        maybe_deliver(user, now)
      rescue StandardError => e
        Buddy::Errors.report(section: "today_scheduler.run", exception: e, user: user)
      end
    end

    def candidate_users
      User.where(id: ByteConversation.where(mode: :buddy).select(:user_id))
    end

    def maybe_deliver(user, now)
      conversation = ByteConversation.where(user_id: user.id, mode: :buddy).order(last_message_at: :desc).first
      return if conversation.nil?
      return if defined?(Buddy::SleepGuard) && Buddy::SleepGuard.sleeping?(user)

      target = target_time(user, now)
      return unless now >= target && now < target + WINDOW
      return if delivered_today?(user, conversation, now)

      Buddy::TodayBriefing.deliver!(user, conversation, scheduled: true)
    end

    # The local Time today when this user's briefing should fire.
    def target_time(user, now)
      first = first_event_before_cutoff(user, now)

      first ? (first - 30.minutes) : Buddy::Day.at(user, hour: FALLBACK[:hour], min: FALLBACK[:min], now: now)
    end

    # The start_at of the perceived day's earliest OWNED, non-cancelled, timed
    # event before 10am local — nil if none. Perceived-day bounded (3am rollover)
    # so the scheduler agrees with the rest of Buddy.
    def first_event_before_cutoff(user, now)
      agenda_ids = Agenda.where(user_id: user.id).pluck(:id)
      return nil if agenda_ids.empty?

      day_start, = Buddy::Day.range(user, now: now)
      cutoff     = Buddy::Day.at(user, hour: CUTOFF_HR, now: now)

      AgendaItem.where(agenda_id: agenda_ids)
        .where.not(status: :cancelled)
        .where(all_day: [false, nil])
        .where(start_at: day_start.utc...cutoff.utc)
        .order(:start_at)
        .limit(1)
        .pick(:start_at)
    end

    def delivered_today?(user, conversation, now)
      day_start, = Buddy::Day.range(user, now: now)
      conversation.byte_messages
        .where(created_at: day_start..)
        .exists?(["metadata->>'source' = ?", "today_scheduled"])
    end
  end
end
