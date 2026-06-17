class Jil::Methods::AgendaItem < Jil::Methods::Base
  PERMIT_ATTRS = [:name, :notes, :location, :arrive_early_minutes, :start_at, :end_at, :color, :metadata].freeze
  GETTER_ATTRS = [
    :id, :kind, :completed_at, :trigger_expression, :agenda_schedule_id, *PERMIT_ATTRS
  ].freeze

  def cast(value)
    case value
    when ::AgendaItem then value
    when ::ActiveRecord::Relation then cast(value.one? ? value.first : value.to_a)
    else load_item(@jil.cast(value, :Hash))
    end
  end

  # Dispatches `.id` / `.name` / `.color` / etc reads on AgendaItem hashes and
  # routes the data-side `#name(String)` / `#start_at(Date)` / etc calls under
  # content blocks to the hash-builder methods below. Everything else
  # (complete, uncomplete, completed?, recurring?, agenda, update!, destroy)
  # falls through to the default Ruby-method dispatch.
  def execute(line)
    method_sym = line.methodname.to_s.underscore.gsub(/[^\w]/, "").to_sym
    case token_class(line.objname)
    when :AgendaItemData
      return send(method_sym, *evalargs(line.args)) if PERMIT_ATTRS.include?(method_sym)
    when :AgendaItem
      return token_val(line.objname)[method_sym] if GETTER_ATTRS.include?(method_sym)
    end
    fallback(line)
  end

  # ---- actions / setters ----

  # Mark this AgendaItem complete. Materialises a phantom into a real row
  # carrying completed_at if the user is acting on an as-yet-untouched
  # recurring occurrence. Returns true on success, false if the item can't
  # be located (e.g. cross-user access attempt or stale phantom id).
  # rubocop:disable Naming/PredicateMethod
  def complete(item_value)
    item = cast(item_value)
    return false if item.blank?

    if item.phantom?
      item.materialize!(completed_at: ::Time.current)
    else
      item.update!(completed_at: ::Time.current)
    end
    item.agenda.broadcast!
    true
  end

  def uncomplete(item_value)
    item = cast(item_value)
    return false if item.blank? || item.phantom?

    item.update!(completed_at: nil)
    item.agenda.broadcast!
    true
  end
  # rubocop:enable Naming/PredicateMethod

  def completed?(item)
    cast(item)&.completed? == true
  end

  def recurring?(item)
    cast(item)&.recurring? == true
  end

  # Parent AgendaSchedule (or nil for standalone items). The return value is
  # a hash with `metadata` carried inline (via serialize_for_edit) so that
  # downstream Jil casts to AgendaSchedule resolve without an extra DB
  # round-trip. Use `.agenda_schedule_id` (Numeric, 0 when standalone) for
  # quick branching without needing nil-comparison gymnastics.
  def agenda_schedule(item_value)
    i = cast(item_value)
    return nil unless i&.agenda_schedule

    i.agenda_schedule.serialize_for_edit
  end

  # Returns a minimal hash describing the parent agenda so Jil tasks can drill
  # in (`item.agenda.name`, `.color`, etc.). `owned` is true iff the agenda
  # belongs to the executing user (i.e. it's "my" calendar, not one I'm
  # accessing via AgendaShare). Lets travel-time tasks treat shared
  # calendars differently — silent prepare, skip notifications, etc.
  def agenda(item)
    i = cast(item)
    return nil unless i

    a = i.agenda
    {
      id:    a.id,
      name:  a.name,
      color: a.color,
      slug:  a.parameterized_name,
      owned: a.user_id == @jil.user.id,
    }
  end

  # Update one or more fields on this AgendaItem. Accepts a content(AgendaItemData)
  # block whose lines build a hash of attrs. Phantoms are materialised first
  # so the change persists. Returns the AgendaItem record — Jil's set_value
  # triggers on the `!` suffix so the caller's variable is reassigned.
  def update!(item_value, details)
    item = cast(item_value)
    return item if item.blank?

    attrs = params(details)
    return item if attrs.empty?

    if item.phantom?
      item.materialize!(attrs)
    else
      item.update!(attrs)
    end
    item.agenda.broadcast!
    item
  end

  def destroy(item_value)
    item = cast(item_value)
    return false if item.blank?
    return false if item.phantom? # nothing persisted to destroy

    agenda = item.agenda
    destroyed = item.destroy.destroyed?
    agenda.broadcast! if destroyed
    destroyed
  end

  # ---- [AgendaItemData] hash builders (used inside content(AgendaItemData) blocks) ----

  def name(text)
    { name: text }
  end

  def notes(text)
    { notes: text }
  end

  def location(text)
    { location: text }
  end

  def arrive_early_minutes(val)
    { arrive_early_minutes: val.to_i }
  end

  def start_at(val)
    { start_at: parse_time(val) }
  end

  def end_at(val)
    { end_at: parse_time(val) }
  end

  def color(text)
    { color: text }
  end

  def metadata(hash)
    { metadata: @jil.cast(hash, :Hash) }
  end

  private

  def params(details)
    @jil.cast(details, :Hash).slice(*PERMIT_ATTRS)
  end

  def parse_time(val)
    return val if val.is_a?(::Time) || val.is_a?(::DateTime)
    return nil if val.blank?

    @jil.user.parse_time(val.to_s)
  end

  def load_item(hash)
    return nil if hash.blank?

    id = hash[:id] || hash["id"]
    return nil if id.blank?

    ::AgendaItem.locate_for_user(id, @jil.user)
  end
end

# *[AgendaItem]
#   .id::Numeric
#   .name::String
#   .kind::String
#   .color::String
#   .start_at::Date
#   .end_at::Date
#   .completed_at::Date
#   .notes::String
#   .location::String
#   .arrive_early_minutes::Numeric
#   .trigger_expression::String
#   .metadata::Hash
#   .agenda::Hash
#   .completed?::Boolean
#   .recurring?::Boolean
#   .complete::Boolean
#   .uncomplete::Boolean
#   .update!(content(AgendaItemData))::Hash
#   .destroy::Boolean
# *[AgendaItemData]
#   #name(String)
#   #notes(String)
#   #location(String)
#   #arrive_early_minutes(Numeric)
#   #start_at(Date)
#   #end_at(Date)
#   #color(String)
#   #metadata(Hash)
