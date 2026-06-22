class Jil::Methods::Agenda < Jil::Methods::Base
  PERMIT_ATTRS = [:name, :color].freeze
  GETTER_ATTRS = [:id, *PERMIT_ATTRS].freeze

  def cast(value)
    case value
    when ::Agenda then value
    when ::ActiveRecord::Relation then cast(value.one? ? value.first : value.to_a)
    else ::SoftAssign.call(::Agenda.new, @jil.cast(value, :Hash))
    end
  end

  # Dispatches `.id` / `.name` / `.color` reads on Agenda hashes and routes the
  # data-side `#name(String)` / `#color(String)` calls under content blocks to
  # the hash-builder methods below. Everything else (items, schedules, etc.)
  # falls through to the default Ruby-method dispatch.
  def execute(line)
    method_sym = line.methodname.to_s.underscore.gsub(/[^\w]/, "").to_sym
    case token_class(line.objname)
    when :AgendaData
      return send(method_sym, *evalargs(line.args)) if PERMIT_ATTRS.include?(method_sym)
    when :Agenda
      return token_val(line.objname)[method_sym] if GETTER_ATTRS.include?(method_sym)
    end
    fallback(line)
  end

  # Soft lookup for voice/text inputs. Tries exact parameterized match,
  # then exact name, then ILIKE substring on either column. Lets
  # "ours" resolve "Ours 💕" and "tasks" resolve "Tasks" without the
  # user having to spell the stored name verbatim.
  def find(name)
    return nil if name.to_s.strip.empty?

    scope = @jil.user.accessible_agendas
    param = name.to_s.parameterize
    return nil if param.empty?

    exact = scope.by_param(name).first || scope.find_by(name: name)
    return exact if exact

    scope.where("parameterized_name ILIKE ?", "%#{param}%").first ||
      scope.where("name ILIKE ?", "%#{name}%").first
  end

  def add_task(agenda_name, item_name, start_at)
    agenda = find(agenda_name)
    return if agenda.blank?

    agenda.agenda_items.create(
      kind:     :task,
      name:     item_name,
      start_at: parse_time(start_at) || next_top_of_hour,
    ).tap { agenda.broadcast! }
  end

  def add_event(agenda_name, item_name, start_at, end_at)
    agenda = find(agenda_name)
    return if agenda.blank?

    agenda.agenda_items.create(
      kind:     :event,
      name:     item_name,
      start_at: parse_time(start_at),
      end_at:   parse_time(end_at),
    ).tap { agenda.broadcast! }
  end

  def items(agenda, date=nil)
    a = load_agenda(agenda)
    return [] if a.blank?

    d = date.present? ? Date.parse(date.to_s) : Date.current
    a.visible_items_for(d).map(&:serialize)
  end

  # Search across all of the user's agenda items using the standard query syntax.
  # Matches the ActionEvent.search signature — limit + order are explicit so
  # the FE editor can offer the same controls.
  # Examples:
  #   Agenda.search("kind:task is:incomplete is:overdue", 50, "ASC")
  #   Agenda.search("is:recurring is:upcoming", nil, nil)
  #
  # Phantom occurrences (recurring items with no DB row yet) are gathered in
  # Ruby alongside the SQL results when the query targets the future-leaning
  # space (`is:upcoming`, `is:today`, `is:recurring`, `is:phantom`) — so daily/weekly
  # recurring tasks appear in dashboard cells without first having to be materialized.
  PHANTOM_QUERY_TRIGGERS = %w[is:upcoming is:today is:recurring is:phantom].freeze
  PHANTOM_WINDOW_DAYS = 30

  # SQL applies the limit so we never pull more than `capped` real rows out of
  # the DB. Phantoms are built in-memory from a small set of schedules over a
  # bounded window — also capped. The merge+sort+take afterwards picks the
  # correct top-N across both sources without ever materializing a full table:
  #
  #   * ASC limit N: SQL gives us the N earliest real items. Phantoms beyond
  #     that window can only DISPLACE them, never reveal a hidden one — SQL
  #     items past position N have start_at >= the Nth, so they can't beat
  #     a phantom.
  #   * DESC limit N: SQL gives us the N latest real items, including any
  #     that are scheduled past PHANTOM_WINDOW_DAYS. Phantoms within the
  #     window slot in at the correct positions.
  def search(query, limit=nil, order=nil)
    materialize_overdue_phantoms_for_today!

    capped = (limit.presence || 50).to_i.clamp(1..200)
    order_sym = [:asc, :desc].include?(order.to_s.downcase.to_sym) ? order.to_s.downcase.to_sym : :asc

    # `is:hidden` / `is:visible` / `is:not-hidden` tokens are pulled out
    # and pushed down to SQL via AgendaPreference's hide scopes — keeps
    # LIMIT accurate and avoids loading then-rejecting rows in Ruby. The
    # rest of the query goes through the normal `is_search` dispatch.
    query_for_db, hidden_filter = split_hidden_state(query)

    # `relation.query(...)` uses `search_scope.where(...)` internally and
    # therefore drops any pre-applied scoping (see ApplicationRecord#query).
    # Apply user scoping AFTER the query — mirrors the Email Jil method.
    scope = ::AgendaItem.query(query_for_db).where(agenda_id: user_agenda_ids)
    scope = apply_hidden_scope_sql(scope, hidden_filter)
    real_items = scope.order(start_at: order_sym).limit(capped).to_a

    phantoms = phantom_results(query_for_db, capped: capped)
    phantoms = apply_hidden_state_ruby(phantoms, hidden_filter) if hidden_filter

    combined = (real_items + phantoms).sort_by(&:start_at)
    combined = combined.reverse if order_sym == :desc

    combined.first(capped).map(&:serialize)
  end

  # Same as search but scoped to a single agenda.
  def find_items(agenda, query, limit=nil, order=nil)
    a = load_agenda(agenda)
    return [] if a.blank?

    materialize_overdue_phantoms_for_today!(agendas: [a])
    query_for_db, hidden_filter = split_hidden_state(query)
    scope = ::AgendaItem.query(query_for_db).where(agenda_id: a.id)
    scope = apply_hidden_scope_sql(scope, hidden_filter)
    apply_search_args(scope, limit, order).map(&:serialize)
  end

  # ---- getters / setters ----

  # Returns this agenda's recurring schedules as an array of hashes ready for
  # the editor (freq, by_day, by_month_day, starts_on, etc.).
  def schedules(agenda)
    a = load_agenda(agenda)
    return [] unless a

    a.agenda_schedules.map(&:serialize_for_edit)
  end

  # Updates an Agenda's name and/or color. Accepts a content(AgendaData) block
  # whose lines call `#name(String)` / `#color(String)` to build the attrs.
  # Returns the updated Agenda record — Jil's set_value triggers on the `!`
  # suffix so the calling variable is reassigned, preserving its type.
  def update!(agenda, details)
    a = load_agenda(agenda)
    return a unless a

    attrs = params(details)
    return a if attrs.blank?

    a.update(attrs)
    a.broadcast!
    a
  end

  def destroy(agenda)
    a = load_agenda(agenda)
    return false unless a

    a.destroy.destroyed?
  end

  # ---- [AgendaData] hash builders (used inside content(AgendaData) blocks) ----

  def name(text)
    { name: text }
  end

  def color(text)
    { color: text }
  end

  private

  def params(details)
    @jil.cast(details, :Hash).slice(*PERMIT_ATTRS)
  end

  def user_agenda_ids
    @jil.user.accessible_agendas.select(:id)
  end

  def apply_search_args(scope, limit, order)
    capped = (limit.presence || 50).to_i.clamp(1..200)
    order_sym = [:asc, :desc].include?(order.to_s.downcase.to_sym) ? order.to_s.downcase.to_sym : :asc
    scope.order(start_at: order_sym).limit(capped).to_a
  end

  HIDDEN_TOKENS  = %w[is:hidden].freeze
  VISIBLE_TOKENS = %w[is:visible is:not-hidden].freeze

  # Returns [cleaned_query, :only_hidden | :only_visible | nil]. Strips
  # any hidden-state tokens out of the query so the rest of the search
  # dispatch (kind, upcoming, etc.) runs unchanged on SQL.
  def split_hidden_state(query)
    str = query.to_s
    tokens = str.split(/\s+/)
    state = nil
    state = :only_hidden if tokens.any? { |t| HIDDEN_TOKENS.include?(t.downcase) }
    state = :only_visible if tokens.any? { |t| VISIBLE_TOKENS.include?(t.downcase) }
    cleaned = tokens.reject { |t|
      d = t.downcase
      HIDDEN_TOKENS.include?(d) || VISIBLE_TOKENS.include?(d)
    }.join(" ")
    [cleaned, state]
  end

  # SQL filter for the real (persisted) rows. Returns the scope unchanged
  # when no hidden-state token was supplied.
  def apply_hidden_scope_sql(scope, state)
    return scope if state.nil?
    pref = ::AgendaPreference.for(@jil.user)
    case state
    when :only_visible then pref.apply_visible_scope(scope)
    when :only_hidden  then pref.apply_hidden_scope(scope)
    else scope
    end
  end

  # Ruby filter for the phantom (in-memory) rows that never hit SQL.
  def apply_hidden_state_ruby(items, state)
    return items if state.nil?
    pref = ::AgendaPreference.for(@jil.user)
    case state
    when :only_hidden  then items.select { |it| pref.item_hidden?(it) }
    when :only_visible then items.reject { |it| pref.item_hidden?(it) }
    else items
    end
  end

  # Gathers phantom occurrences in the next PHANTOM_WINDOW_DAYS days and
  # filters them in-memory against the query's recognized state tokens. Only
  # runs when the query references future-leaning state (upcoming/today/recurring),
  # since phantoms are by definition future occurrences.
  #
  # Two SQL queries total regardless of user size:
  #   1. Pull this user's active schedules in window (small — schedules are bounded).
  #   2. Bulk-pluck (schedule_id, start_at) of already-materialized rows so we
  #      can skip emitting duplicate phantoms — no per-iteration .exists?.
  # Real items in the window are NOT loaded; the SQL scope above already
  # surfaces them through the main `search` path.
  def phantom_results(query, capped:)
    tokens = query.to_s.downcase.split(/\s+/)
    return [] unless tokens.any? { |t| PHANTOM_QUERY_TRIGGERS.include?(t) }

    user = @jil.user
    agenda_ids = user.accessible_agendas.pluck(:id)
    return [] if agenda_ids.empty?

    from_date = ::Date.current
    to_date = from_date + PHANTOM_WINDOW_DAYS

    schedules = ::AgendaSchedule
      .where(agenda_id: agenda_ids)
      .active_between(from_date, to_date)
      .includes(:agenda)
      .to_a
    return [] if schedules.empty?

    materialized = materialized_phantom_keys(agenda_ids, schedules.map(&:id), user, from_date, to_date)

    phantoms = []
    schedules.each do |schedule|
      (from_date..to_date).each do |date|
        next unless schedule.matches?(date)
        next if materialized.include?([schedule.id, date])

        candidate = schedule.build_phantom(date)
        next unless phantom_matches?(candidate, tokens)

        phantoms << candidate
        # Phantoms in the window are bounded by capped real rows + phantoms,
        # but cap them too so a runaway daily schedule with 30 occurrences
        # doesn't dominate. Two windows worth is plenty headroom for the
        # combined sort downstream.
        return phantoms if phantoms.size >= capped * 2
      end
    end
    phantoms
  end

  # Single SQL — pulls only (schedule_id, start_at) for rows already covering
  # phantom dates, keyed in a Set for O(1) dedupe checks.
  def materialized_phantom_keys(agenda_ids, schedule_ids, user, from_date, to_date)
    zone = ::ActiveSupport::TimeZone[user.timezone] || ::Time.zone
    from_ts = zone.local(from_date.year, from_date.month, from_date.day).beginning_of_day
    to_ts = zone.local(to_date.year, to_date.month, to_date.day).end_of_day

    rows = ::AgendaItem.where(
      agenda_id:          agenda_ids,
      agenda_schedule_id: schedule_ids,
      detached_at:        nil,
      start_at:           from_ts..to_ts,
    ).pluck(:agenda_schedule_id, :start_at)

    rows.each_with_object(::Set.new) { |(sid, ts), set|
      set << [sid, ts.in_time_zone(user.timezone).to_date]
    }
  end

  def phantom_matches?(item, tokens)
    tokens.all? { |token| phantom_token_matches?(item, token) }
  end

  def phantom_token_matches?(item, token)
    return item.kind.to_s == ::Regexp.last_match(1).singularize if token.match(/\Akind:(\w+)\z/)
    return phantom_is_match?(item, ::Regexp.last_match(1)) if token.match(/\Ais:(\w+)\z/)

    true
  end

  def phantom_is_match?(item, state)
    case state.downcase
    when "task", "tasks"                     then item.task?
    when "event", "events"                   then item.event?
    when "trigger", "triggers"               then item.trigger?
    when "completed", "complete", "detached" then false # phantoms never completed/detached
    when "incomplete", "pending", "phantom"  then true  # phantoms always incomplete + phantom
    when "upcoming"                          then item.start_at >= ::Time.current
    when "past"                              then item.start_at < ::Time.current
    when "today"                             then item.start_at.in_time_zone(@jil.user.timezone).to_date == ::Date.current
    when "overdue"                           then !item.event? && item.start_at < ::Time.current
    when "recurring"                         then item.recurring?
    else true
    end
  end

  # Phantoms (recurring occurrences with no DB row yet) can't be found by
  # SQL queries. When a user runs `Agenda.search`, materialize any of TODAY's
  # phantoms whose scheduled time has already passed so the SQL query finds
  # them. Bounded by today only — one query per schedule, one INSERT max per
  # schedule.
  def materialize_overdue_phantoms_for_today!(agendas: @jil.user.accessible_agendas)
    now = ::Time.current
    today = ::Date.current

    agendas.find_each do |agenda|
      # Events never need on-demand materialization — they auto-disappear when
      # their end_at passes and aren't "overdue" by definition.
      schedules = agenda.agenda_schedules.where(starts_on: ..today).where.not(kind: :event)
      schedules.find_each do |schedule|
        next unless schedule.matches?(today)

        occ_start = schedule.occurrence_start_at(today)
        next if occ_start > now
        next if schedule.agenda_items.exists?(start_at: agenda.send(:day_range, today))

        schedule.agenda_items.create!(
          agenda:             agenda,
          kind:               schedule.kind,
          start_at:           occ_start,
          end_at:             schedule.occurrence_end_at(today),
          name:               schedule.name,
          notes:              schedule.notes,
          location:           schedule.location,
          color:              schedule.color,
          trigger_expression: schedule.trigger_expression,
        )
      end
    end
  end

  def parse_time(val)
    return val if val.is_a?(::Time) || val.is_a?(::DateTime)
    return nil if val.to_s.strip.empty?

    @jil.user.parse_time(val.to_s)
  end

  def next_top_of_hour
    @jil.user.timezone { Time.current.change(min: 0, sec: 0) + 1.hour }
  end

  def load_agenda(value)
    return value if value.is_a?(::Agenda)

    @jil.user.accessible_agendas.find_by(id: cast(value)[:id])
  end
end

# [Agenda]
#   #find(String)
#   #add_task(String:Agenda String:Name String:When)
#   #add_event(String:Agenda String:Name String:Start String:End)
#   #search(Text:Query "limit" Numeric(50) TAB "order" ["DESC" "ASC"])::Array
#   .id::Numeric
#   .name::String
#   .color::String
#   .items(String?:Date)::Array
#   .schedules::Array
#   .find_items(String:Query "limit" Numeric(50) TAB "order" ["DESC" "ASC"])::Array
#   .update!(content(AgendaData))::Hash
#   .destroy::Boolean
# *[AgendaData]
#   #name(String)
#   #color(String)
