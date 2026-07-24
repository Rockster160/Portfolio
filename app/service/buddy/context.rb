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

      {
        now_local:         now.strftime("%a %Y-%m-%d %-I:%M %p %Z"),
        timezone:          tz,
        user_first_name:   user.first_name,
        today_agenda:      today_agenda(user, now),
        chores_marked_due: chores_marked_due(user),
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

      def chores_marked_due(user)
        return [] unless user.respond_to?(:accessible_chores)

        user.accessible_chores.select { |c| c.respond_to?(:marked_due?) && c.marked_due? }.first(15).map { |c|
          {
            id:   c.id,
            name: c.name,
          }
        }
      rescue => e
        Rails.logger.warn("[Buddy::Context] chores_marked_due failed: #{e.class}: #{e.message}")
        []
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
