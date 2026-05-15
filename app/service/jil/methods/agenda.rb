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

  def find(name)
    scope = @jil.user.accessible_agendas
    scope.by_param(name).first || scope.find_by(name: name)
  end

  def add_task(agenda_name, item_name, start_at)
    agenda = find(agenda_name)
    return if agenda.blank?

    agenda.agenda_items.create(
      kind:     :task,
      name:     item_name,
      start_at: parse_time(start_at),
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
  #   Agenda.search("kind:task incomplete overdue", 50, "ASC")
  #   Agenda.search("recurring upcoming", nil, nil)
  #
  # Materializes today's past-due phantoms first so recurring occurrences
  # whose time has passed appear in the result alongside one-off items.
  def search(query, limit=nil, order=nil)
    materialize_overdue_phantoms_for_today!
    # `relation.query(...)` uses `search_scope.where(...)` internally and
    # therefore drops any pre-applied scoping (see ApplicationRecord#query).
    # Apply user scoping AFTER the query — mirrors the Email Jil method.
    scope = ::AgendaItem.query(query).where(agenda_id: user_agenda_ids)
    apply_search_args(scope, limit, order).map(&:serialize)
  end

  # Same as search but scoped to a single agenda.
  def find_items(agenda, query, limit=nil, order=nil)
    a = load_agenda(agenda)
    return [] if a.blank?

    materialize_overdue_phantoms_for_today!(agendas: [a])
    scope = ::AgendaItem.query(query).where(agenda_id: a.id)
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
    scope.order(start_at: order_sym).limit(capped)
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

    @jil.user.parse_time(val.to_s)
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
