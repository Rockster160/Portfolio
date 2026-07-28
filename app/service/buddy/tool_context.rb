module Buddy
  # Passed to every tool's confirm/label/execute/receipt proc. Wraps the
  # user + current proposal state and centralizes the "resolve a fuzzy name
  # to a domain record" logic so tool files stay short.
  #
  # Resolvers return the top candidate silently; ambiguity is the persona's
  # problem (it should ask the user via a follow-up message).
  class ToolContext
    attr_reader :user, :proposal

    def initialize(user, proposal: nil)
      @user     = user
      @proposal = proposal
    end

    # ---- chores ----

    def resolve_chore(name)
      return nil if name.blank?

      needle = name.to_s.downcase.strip
      candidates = user.accessible_chores.to_a
      exact = candidates.find { |c| c.name.to_s.downcase == needle }
      return exact if exact

      candidates.find { |c| c.name.to_s.downcase.include?(needle) } ||
        candidates.min_by { |c| levenshtein(c.name.to_s.downcase, needle) }
    end

    def resolve_chore_completion(chore_or_name, hint: :last)
      chore = chore_or_name.is_a?(Chore) ? chore_or_name : resolve_chore(chore_or_name)
      return nil if chore.nil?

      scope = ChoreCompletion.where(chore_id: chore.id, user_id: user.id)
      case hint.to_sym
      when :today     then scope.where("completed_at >= ?", user.perceived_today.beginning_of_day).order(completed_at: :desc).first
      when :yesterday then scope.where(completed_at: (user.perceived_today - 1.day).all_day).order(completed_at: :desc).first
      else                 scope.order(completed_at: :desc).first
      end
    end

    # ---- lists ----

    def resolve_list(name)
      user.list_by_name(name.to_s)
    end

    def resolve_list_item(list_or_name, item_name)
      list = list_or_name.is_a?(List) ? list_or_name : resolve_list(list_or_name)
      return nil if list.nil?

      list.list_items.by_formatted_name(item_name.to_s)
    end

    # ---- events ----

    def resolve_event(name, hint: :last)
      return nil if name.blank?

      scope = user.action_events.where("LOWER(name) LIKE ?", "%#{name.to_s.downcase}%")
      case hint.to_s
      when "today"        then scope.where("timestamp >= ?", user.perceived_today.beginning_of_day).order(timestamp: :desc).first
      when "yesterday"    then scope.where(timestamp: (user.perceived_today - 1.day).all_day).order(timestamp: :desc).first
      when "this morning" then scope.where(timestamp: user.perceived_today.beginning_of_day..user.perceived_today.change(hour: 12)).order(timestamp: :desc).first
      when /^\d+$/        then scope.find_by(id: hint.to_i)
      else                     scope.order(timestamp: :desc).first
      end
    end

    # ---- agenda ----

    def resolve_agenda_item(title, hint_date: nil)
      return nil if title.blank?

      needle = title.to_s.downcase.strip
      agendas = Agenda.where(user_id: user.id).pluck(:id)
      scope = AgendaItem.where(agenda_id: agendas)
      scope = scope.where("LOWER(title) LIKE ?", "%#{needle}%")
      if hint_date.present?
        day = (Time.zone.parse(hint_date.to_s) rescue nil)
        scope = scope.where("start_at >= ? AND start_at < ?", day.beginning_of_day, day.end_of_day) if day
      end
      scope.order(start_at: :asc).first
    end

    # ---- times ----

    def resolve_time(iso)
      Time.zone.parse(iso.to_s)
    rescue ArgumentError
      nil
    end

    # Friendly future phrasing for a receipt/confirmation, in the user's zone:
    #   today            → "at 6:01pm"
    #   tomorrow         → "tomorrow at 6:01pm"
    #   within this week → "this Wednesday at 6:01pm"
    #   next week        → "next Wednesday at 6:01pm"
    #   further out      → "on Jul 15 at 6:01pm"
    # On-the-hour times drop the minutes ("6pm"). all_day drops the time.
    def friendly_future(time, all_day: false)
      return "later" if time.nil?

      local = time.in_time_zone(user.timezone)
      today = Time.current.in_time_zone(user.timezone).to_date
      days  = (local.to_date - today).to_i

      day_prefix = case days
      when 0     then ""
      when 1     then "tomorrow "
      when 2..6  then "this #{local.strftime("%A")} "
      when 7..13 then "next #{local.strftime("%A")} "
      else            "on #{local.strftime("%b %-d")} "
      end

      return "#{day_prefix.strip.presence || 'today'}".strip if all_day

      time_str = local.strftime("%-I:%M%P").sub(":00", "")  # "6:01pm" / "6pm"
      "#{day_prefix}at #{time_str}"
    end

    # ---- household ----

    def resolve_household_user(name)
      return user if name.to_s.downcase.in?(%w[me myself i])
      return nil if user.chore_household_id.nil?

      candidates = User.where(id: user.chore_household&.member_user_ids || [])
      candidates.find { |u| u.first_name.to_s.downcase == name.to_s.downcase } ||
        candidates.find { |u| u.name.to_s.downcase.include?(name.to_s.downcase) }
    end

    private

    def levenshtein(a, b)
      m, n = a.length, b.length
      return n if m.zero?
      return m if n.zero?

      d = Array.new(m + 1) { Array.new(n + 1, 0) }
      (0..m).each { |i| d[i][0] = i }
      (0..n).each { |j| d[0][j] = j }
      (1..m).each { |i|
        (1..n).each { |j|
          cost = a[i - 1] == b[j - 1] ? 0 : 1
          d[i][j] = [d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost].min
        }
      }
      d[m][n]
    end
  end
end
