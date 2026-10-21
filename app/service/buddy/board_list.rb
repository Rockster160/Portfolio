module Buddy
  # A list connected to a board: each of its items is a circle, and a press
  # checks the item off the list. A checked item stays on the board, done, for
  # the board's `clear_after` (seconds, or until the chore day ends) and then
  # goes.
  #
  # Items can carry a priority, matched from the board's own settings: by default
  # an item in a section named "Very High" is very high and one in "High" is
  # high. The newest high item is what the pet says on the board; the newest very
  # high one is what it dreams of, shouting until it's checked off.
  #
  # Stored on the board as `metadata.board_list`.
  module BoardList
    module_function

    DEFAULT_CLEAR_AFTER = 1.hour.to_i
    MAX_CLEAR_AFTER = 7.days.to_i
    PRIORITIES = [:very_high, :high].freeze
    DEFAULT_MATCHERS = { very_high: "Very High", high: "High" }.freeze
    REGEX_TIMEOUT = 0.1

    # What the board is set to, defaults filled in. `list_id` is nil when no
    # list is connected.
    def settings(convo)
      raw = convo.metadata.is_a?(Hash) ? convo.metadata["board_list"].to_h : {}
      {
        list_id:     raw["list_id"].presence&.to_i,
        clear_after: clear_after(raw["clear_after"]) || DEFAULT_CLEAR_AFTER,
        very_high:   raw.key?("very_high") ? raw["very_high"].to_s : DEFAULT_MATCHERS[:very_high],
        high:        raw.key?("high") ? raw["high"].to_s : DEFAULT_MATCHERS[:high],
      }
    end

    # The connected list, when its board's owner can still reach it.
    def list_for(convo)
      id = settings(convo)[:list_id]
      id && convo.user.lists.find_by(id: id)
    end

    # The settings as the page reads them, with the list's name for the row
    # that says how the board is set.
    def wire(convo)
      settings(convo).merge(list_name: list_for(convo)&.name)
    end

    # Seconds, or :end_of_day; nil for anything else, or longer than a week.
    def clear_after(value)
      return :end_of_day if value.to_s == "end_of_day"
      return nil unless value.to_s.match?(/\A\d+\z/)

      seconds = value.to_i
      seconds <= MAX_CLEAR_AFTER ? seconds : nil
    end

    # Why a matcher can't be used, or nil. Only a /pattern/ can be wrong.
    def matcher_error(text)
      terms(text).filter_map { |term| term[:error] }.first
    end

    # Connect a list (or disconnect, with a blank `list_id`) and set how it
    # behaves. Raises ArgumentError with the reason on anything unusable.
    def save!(convo, list_id:, clear_after:, very_high:, high:)
      if list_id.blank?
        convo.metadata = convo.metadata.to_h.except("board_list")
        return convo.save!
      end

      list = convo.user.lists.find_by(id: list_id)
      raise ArgumentError, "That list isn't one of yours." if list.nil?

      clear = clear_after(clear_after)
      raise ArgumentError, "Checked items can stay for up to a week." if clear.nil?

      [very_high, high].each do |text|
        error = matcher_error(text)
        raise ArgumentError, error if error
      end

      convo.metadata = convo.metadata.to_h.merge(
        "board_list" => {
          "list_id"     => list.id,
          "clear_after" => clear.to_s,
          "very_high"   => very_high.to_s.strip,
          "high"        => high.to_s.strip,
        },
      )
      convo.save!
    end

    # The list's items as board circles: very high first, then high, then the
    # rest, each newest first the way the list orders them. Checked items stay
    # while they're inside the board's window; permanent ones can't be checked
    # off, so they aren't here.
    def items(convo, now: Time.current)
      list = list_for(convo)
      return [] if list.nil?

      config = settings(convo)
      since = checked_since(convo.user, config[:clear_after], now)
      scope = list.list_items.with_deleted.where(permanent: false).includes(:section)
      scope = scope.where("list_items.deleted_at IS NULL OR list_items.deleted_at >= ?", since)
      matchers = matchers_for(config)

      wires = scope.ordered.map { |item| item_wire(convo, item, config, matchers) }
      wires.sort_by.with_index { |wire, index| [rank_of(wire[:priority]), index] }
    end

    # One item as a circle.
    def item_wire(convo, item, config=settings(convo), matchers=matchers_for(config))
      glyph, label = split_glyph(item.name.to_s)
      {
        kind:       :list,
        id:         item.id,
        name:       item.name,
        short_name: label,
        icon:       glyph,
        icon_kind:  glyph ? :emoji : :empty,
        priority:   priority(item, matchers),
        rank:       item.sort_order.to_i,
        section:    item.section&.name,
        checked:    item.deleted?,
        clears_at:  item.deleted? ? clears_at(convo.user, config[:clear_after], item.deleted_at)&.iso8601(3) : nil,
      }
    end

    def matchers_for(config)
      PRIORITIES.index_with { |level| terms(config[level]) }
    end

    def rank_of(priority)
      PRIORITIES.index(priority) || PRIORITIES.size
    end

    def priority(item, matchers)
      PRIORITIES.find { |level| matchers[level].any? { |term| term[:match]&.call(item) } } || :normal
    end

    # A leading emoji is the circle's picture and the rest its name; without
    # one, the name itself goes on the circle.
    def split_glyph(name)
      first = name[/\A\X/].to_s
      return [nil, name.strip] unless first.match?(/\p{Extended_Pictographic}/)

      rest = name.delete_prefix(first).strip
      [first, rest.presence || name.strip]
    end

    # Comma-separated section names, matched the way the list matches a typed
    # `[Section]` (case and punctuation aside), or a /pattern/ on the item's own
    # name.
    def terms(text)
      text.to_s.split(",").map(&:strip).compact_blank.map { |term|
        pattern = term[%r{\A/(.+)/i?\z}, 1]
        next section_term(term) if pattern.nil?

        begin
          regex = Regexp.new(pattern, Regexp::IGNORECASE, timeout: REGEX_TIMEOUT)
          { match: ->(item) { regex.match?(item.name.to_s) } }
        rescue RegexpError => e
          { error: "#{term} isn't a pattern that can be read: #{e.message}" }
        end
      }
    end

    def section_term(name)
      wanted = soft_name(name)
      { match: ->(item) { item.section.present? && soft_name(item.section.name) == wanted } }
    end

    # Section#where_soft_name's normalization, in Ruby.
    def soft_name(name)
      name.to_s.gsub(/[^\w\s\d]/, "").downcase.squish
    end

    # How far back a checked item is still shown.
    def checked_since(user, clear_after, now)
      return ::ChoreDay.starts_at(::ChoreDay.current(user, at: now), user) if clear_after == :end_of_day

      now - clear_after.to_i.seconds
    end

    def clears_at(user, clear_after, checked_at)
      return ::ChoreDay.ends_at(::ChoreDay.current(user, at: checked_at), user) if clear_after == :end_of_day

      checked_at + clear_after.to_i.seconds
    end

    # The boards showing a list, told it changed so they fetch it again. Sent to
    # everyone who may be looking at one: the owner, or their household for a
    # shared board.
    def broadcast!(list)
      boards = ::ByteConversation.active.board.where("metadata->'board_list'->>'list_id' = ?", list.id.to_s)
      boards = boards.includes(:user).to_a
      return if boards.empty?

      user_ids = boards.flat_map { |board|
        board.shared? ? board.user.chore_household_user_ids : [board.user_id]
      }.uniq
      payload = {
        id:      :byte,
        channel: :byte,
        data:    { kind: :board_list, list_id: list.id },
      }
      ::AfterCommit.run {
        ::User.where(id: user_ids).find_each { |user| ::MonitorChannel.broadcast_to(user, payload) }
      }
    end
  end
end
