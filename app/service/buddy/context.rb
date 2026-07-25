module Buddy
  # Snapshot injected into the system prompt each turn so Buddy can reference
  # today's agenda, recent events, chore state, etc. Kept intentionally small
  # (target < 1.5 KB) — this ships with every turn.
  module Context
    module_function

    RECENT_EVENT_WINDOW = 24.hours
    UPCOMING_AGENDA_WINDOW = 24.hours

    def build(user)
      tz = user.timezone
      now = Time.current.in_time_zone(tz)
      today = user.perceived_today

      chore_buckets = build_chore_buckets(user, today)

      {
        now_local:         now.strftime("%a %Y-%m-%d %-I:%M %p %Z"),
        timezone:          tz,
        user_first_name:   user.first_name,
        emotional_state:   emotional_state(user, now),          # current mood + pet expression
        today_agenda:      today_agenda(user, now),
        chores_dailies:         chore_buckets[:dailies],         # MOST PROMINENT — the daily rotation
        chores_scheduled_today: chore_buckets[:scheduled_today], # explicit today scheduling
        chores_hot_picks:       chore_buckets[:hot_picks],       # attention items
        chores_overdue_backlog: chore_buckets[:overdue_backlog], # long-term todo, NOT all-must-do-today
        recent_events:     recent_events(user, now),
        active_proposals:  active_proposals(user),
      }
    end

    class << self
      private

      def today_agenda(user, now)
        agenda_ids = Agenda.where(user_id: user.id).pluck(:id)
        return [] if agenda_ids.empty?

        AgendaItem.where(agenda_id: agenda_ids)
          .where(status: [nil, "confirmed", "tentative"])
          .where("start_at >= ? AND start_at < ?", now.beginning_of_day.utc, (now + UPCOMING_AGENDA_WINDOW).utc)
          .order(:start_at)
          .limit(20)
          .map { |i|
            {
              id:      i.id,
              time:    (i.all_day ? "all day" : i.start_at.in_time_zone(user.timezone).strftime("%-I:%M %p")),
              title:   i.title,
              cal:     i.agenda&.name,
              kind:    i.kind,
            }
          }
      rescue => e
        Rails.logger.warn("[Buddy::Context] today_agenda failed: #{e.class}: #{e.message}")
        []
      end

      # Four buckets with distinct meanings — Rocco was explicit that
      # overdue-scheduled chores are a long-term backlog, NOT today's
      # must-dos. The buckets let Buddy talk about the day accurately
      # instead of treating a big overdue count as "you're behind".
      #
      #   dailies         — user's daily rotation (ChoreDaily). Most prominent.
      #   scheduled_today — chores whose schedule matches TODAY. Good to know.
      #   hot_picks       — flagged for attention today (ChoreHotPick).
      #   overdue_backlog — marked_due AND not in any of the above. Long-term todo.
      def build_chore_buckets(user, today)
        return default_buckets unless user.respond_to?(:accessible_chores) && user.chore_household_id

        chores = user.accessible_chores.to_a
        by_id  = chores.each_with_object({}) { |c, h| h[c.id] = c }

        daily_ids = ChoreDaily.for_user(user).limit(20).pluck(:chore_id)
        hot_ids   = ChoreHotPick.for_day(today).where(chore_id: chores.map(&:id)).pluck(:chore_id)
        scheduled_today_ids = chores.select { |c|
          c.respond_to?(:matches_day?) && c.scheduled? && (safe_matches_day(c, today, user))
        }.map(&:id)

        prominent = (daily_ids + hot_ids + scheduled_today_ids).uniq
        overdue = chores.select { |c|
          c.respond_to?(:marked_due?) && c.marked_due? && !prominent.include?(c.id)
        }.map(&:id)

        {
          dailies:         daily_ids.filter_map { |id| slim_chore(by_id[id]) }.first(15),
          scheduled_today: scheduled_today_ids.filter_map { |id| slim_chore(by_id[id]) }.first(15),
          hot_picks:       hot_ids.filter_map { |id| slim_chore(by_id[id]) }.first(15),
          overdue_backlog: overdue.filter_map { |id| slim_chore(by_id[id]) }.first(20),
        }
      rescue => e
        Rails.logger.warn("[Buddy::Context] chore buckets failed: #{e.class}: #{e.message}")
        default_buckets
      end

      # Emotional state block. `pet_expression` is the tracked mood —
      # the LLM controls it via `[[mood: X]]` markers, it persists on
      # users.buddy_expression, it ships back in every context turn.
      # `last_check_in` is optional richer detail from an explicit
      # Check-in button tap if one exists in recent history.
      def emotional_state(user, now)
        latest_check_in = user.action_events
          .where(name: "check_in")
          .order(timestamp: :desc)
          .limit(1)
          .first
        check_in_summary = if latest_check_in
          {
            level:     (latest_check_in.data.is_a?(Hash) ? latest_check_in.data["mood"] : nil),
            at:        latest_check_in.timestamp.in_time_zone(user.timezone).strftime("%-I:%M %p"),
            hours_ago: ((now - latest_check_in.timestamp) / 1.hour).round(1),
          }
        end

        {
          pet_expression: user.buddy_expression,
          last_check_in:  check_in_summary,
        }
      end

      def default_buckets
        { dailies: [], scheduled_today: [], hot_picks: [], overdue_backlog: [] }
      end

      def slim_chore(chore)
        return nil if chore.nil?

        out = { id: chore.id, name: chore.name }
        out[:freq] = chore.freq.to_s if chore.respond_to?(:freq) && chore.freq.present?
        if chore.respond_to?(:assigned?) && chore.assigned?
          out[:assigned_to] = chore.assigned_to_user&.first_name
        end
        out
      end

      # `matches_day?` on some chore types raises on malformed recurrence
      # data; a Buddy context build must never blow up over a single bad chore.
      def safe_matches_day(chore, day, user)
        chore.matches_day?(day, user)
      rescue
        false
      end

      def recent_events(user, now)
        return [] unless user.respond_to?(:action_events)

        user.action_events
          .where("timestamp >= ?", now - RECENT_EVENT_WINDOW)
          .order(timestamp: :desc)
          .limit(15)
          .map { |e|
            {
              id:    e.id,
              name:  e.name,
              at:    e.timestamp.in_time_zone(user.timezone).strftime("%-I:%M %p"),
              notes: e.notes.to_s.first(60),
            }
          }
      rescue => e
        Rails.logger.warn("[Buddy::Context] recent_events failed: #{e.class}: #{e.message}")
        []
      end

      def active_proposals(user)
        ByteAction.active
          .where(user_id: user.id, tool_name: "buddy_proposals")
          .limit(5)
          .flat_map { |a|
            Array(a.buttons).map { |b|
              {
                id:   b["id"],
                tool: b["tool_name"],
                summary: b["label"],
              }
            }
          }
      rescue => e
        Rails.logger.warn("[Buddy::Context] active_proposals failed: #{e.class}: #{e.message}")
        []
      end
    end
  end
end
