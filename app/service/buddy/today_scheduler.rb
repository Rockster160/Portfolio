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
      tz    = user.timezone.presence || "America/Denver"
      local = now.in_time_zone(tz)
      first = first_event_before_cutoff(user, local)

      first ? (first - 30.minutes) : local.change(hour: FALLBACK[:hour], min: FALLBACK[:min], sec: 0)
    end

    # The start_at of today's earliest OWNED, non-cancelled, timed event that
    # begins before 10am local — nil if there isn't one.
    def first_event_before_cutoff(user, local)
      agenda_ids = Agenda.where(user_id: user.id).pluck(:id)
      return nil if agenda_ids.empty?

      bod    = local.beginning_of_day
      cutoff = local.change(hour: CUTOFF_HR, min: 0, sec: 0)

      AgendaItem.where(agenda_id: agenda_ids)
        .where.not(status: :cancelled)
        .where(all_day: [false, nil])
        .where(start_at: bod.utc...cutoff.utc)
        .order(:start_at)
        .limit(1)
        .pick(:start_at)
    end

    def delivered_today?(user, conversation, now)
      bod = now.in_time_zone(user.timezone.presence || "America/Denver").beginning_of_day
      conversation.byte_messages
        .where(created_at: bod..)
        .exists?(["metadata->>'source' = ?", "today_scheduled"])
    end
  end
end
