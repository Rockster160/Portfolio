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

    # The local Time today when this user's briefing should fire: 30 minutes
    # before DEPARTURE for the first event (start − known drive time − 30), so a
    # 9am meeting with a 25-min drive briefs at ~8:05, not 8:30. Falls back to
    # start − 30 when there's no known drive, and to 8:30am with no early event.
    def target_time(user, now)
      first = first_event_before_cutoff(user, now)
      return Buddy::Day.at(user, hour: FALLBACK[:hour], min: FALLBACK[:min], now: now) if first.nil?

      first.start_at - (drive_minutes(first) + 30).minutes
    end

    # The perceived day's earliest OWNED, non-cancelled, timed event before 10am
    # local — nil if none. Perceived-day bounded (3am rollover) so the scheduler
    # agrees with the rest of Buddy.
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
        .first
    end

    # Known drive time (minutes) from the travel-chain sync on the item's
    # metadata; 0 when there's none.
    def drive_minutes(item)
      travel = item.metadata.is_a?(Hash) ? item.metadata["travel"] : nil
      mins   = travel.is_a?(Hash) ? travel["travel_minutes"].to_i : 0
      mins.positive? ? mins : 0
    end

    def delivered_today?(user, conversation, now)
      day_start, = Buddy::Day.range(user, now: now)
      conversation.byte_messages
        .where(created_at: day_start..)
        .exists?(["metadata->>'source' = ?", "today_scheduled"])
    end
  end
end
