class Jil::Methods::AgendaSchedule < Jil::Methods::Base
  PERMIT_ATTRS = [:name, :notes, :location, :arrive_early_minutes, :color, :metadata].freeze
  GETTER_ATTRS = [
    :id, :kind, :starts_on, :until_on, *PERMIT_ATTRS
  ].freeze

  def cast(value)
    case value
    when ::AgendaSchedule then value
    when ::ActiveRecord::Relation then cast(value.one? ? value.first : value.to_a)
    else load_schedule(@jil.cast(value, :Hash))
    end
  end

  # Mirrors Jil::Methods::AgendaItem#execute — routes getter reads on
  # AgendaSchedule values + hash-builder calls under AgendaScheduleData
  # blocks, falls back to default Ruby-method dispatch for everything else
  # (e.g. `update!`, `future_agenda_items`).
  def execute(line)
    method_sym = line.methodname.to_s.underscore.gsub(/[^\w]/, "").to_sym
    case token_class(line.objname)
    when :AgendaScheduleData
      return send(method_sym, *evalargs(line.args)) if PERMIT_ATTRS.include?(method_sym)
    when :AgendaSchedule
      return token_val(line.objname)[method_sym] if GETTER_ATTRS.include?(method_sym)
    end
    fallback(line)
  end

  # ---- actions / setters ----

  # metadata is deep-merged onto the existing column rather than replaced,
  # matching Jil::Methods::AgendaItem#update! — a Jil task that writes one
  # key can't accidentally wipe out sibling travel-chain or other-writer
  # fields.
  def update!(schedule_value, details)
    schedule = cast(schedule_value)
    return schedule if schedule.blank?

    attrs = params(details)
    return schedule if attrs.empty?

    merge_metadata!(schedule, attrs)

    schedule.update!(attrs)
    schedule
  end

  def agenda(schedule_value)
    s = cast(schedule_value)
    return nil unless s

    { id: s.agenda.id, name: s.agenda.name, color: s.agenda.color }
  end

  # Start_at of the next future materialized occurrence under this
  # schedule, or nil if there are none. Used by the Schedule Travel
  # Compute task to pass a real arrival_time hint to Google Distance
  # Matrix so the cached travel_minutes reflects predicted traffic at
  # the actual arrival window, not the schedule's create time.
  def next_occurrence_at(schedule_value)
    schedule = cast(schedule_value)
    return nil unless schedule

    schedule.agenda_items
      .where("start_at > ?", ::Time.current)
      .order(:start_at)
      .pick(:start_at)
  end

  # Future (start_at > now) materialized items under this schedule.
  # Phantoms aren't covered here — they materialize lazily on view and
  # the :agenda_item :created trigger fires through the item-level
  # travel task at that point.
  def future_agenda_items(schedule_value)
    schedule = cast(schedule_value)
    return [] if schedule.blank?

    schedule.agenda_items
      .where("start_at > ?", ::Time.current)
      .map { |item| item.serialize.with_indifferent_access }
  end

  # ---- [AgendaScheduleData] hash builders ----

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

  def merge_metadata!(schedule, attrs)
    return unless attrs.key?(:metadata)

    incoming = attrs[:metadata].to_h.deep_stringify_keys
    existing = (schedule.metadata.presence || {}).deep_stringify_keys
    attrs[:metadata] = existing.deep_merge(incoming)
  end

  def load_schedule(hash)
    return nil if hash.blank?

    id = hash[:id] || hash["id"]
    return nil if id.blank?

    ::AgendaSchedule.where(agenda_id: @jil.user.accessible_agendas.select(:id)).find_by(id: id)
  end
end

# *[AgendaSchedule]
#   .id::Numeric
#   .name::String
#   .kind::String
#   .color::String
#   .location::String
#   .arrive_early_minutes::Numeric
#   .notes::String
#   .starts_on::Date
#   .until_on::Date
#   .metadata::Hash
#   .agenda::Hash
#   .next_occurrence_at::Date
#   .future_agenda_items::Array
#   .update!(content(AgendaScheduleData))::Hash
# *[AgendaScheduleData]
#   #name(String)
#   #notes(String)
#   #location(String)
#   #arrive_early_minutes(Numeric)
#   #color(String)
#   #metadata(Hash)
