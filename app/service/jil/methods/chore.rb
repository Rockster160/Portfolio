# Jil bindings for the Chores system. Lets Jil tasks find chores,
# complete them, look up the user's balance, list today's chores, and
# wire ActionEvent names to auto-complete a chore (via ChoreEventMapping).
class Jil::Methods::Chore < Jil::Methods::Base
  def cast(value)
    case value
    when ::Chore                      then value
    when ::Numeric                    then find_by_id(value)
    when ::ActiveRecord::Relation     then cast(value.one? ? value.first : value.to_a)
    when ::Hash                       then find_by_attrs(value)
    when ::String                     then find_by_name(value)
    else nil
    end
  end

  # Chore.find("Vitamins") → first chore whose name contains "Vitamins"
  # (case-insensitive). Scoped to the user's accessible set so household
  # chores resolve too.
  def find(name)
    find_by_name(name)
  end

  # Chore.scheduled_today → array of Chore records visible on Today.
  def scheduled_today
    ctx = ChoreSerializerContext.for_user(@jil.user)
    chore_ids = ctx.serialize_all(@jil.user.accessible_chores.to_a)
      .select { |c| c[:today_visible] }.map { |c| c[:id] }
    Chore.where(id: chore_ids).to_a
  end

  # Chore.accessible → every chore the user can see (personal +
  # household + assigned-to-me).
  def accessible
    @jil.user.accessible_chores.to_a
  end

  # Chore.complete("Vitamins"[, timestamp]) → run a completion at now
  # (or the supplied timestamp) and return the ChoreCompletion. Returns
  # nil if no matching chore was found. Honors the chore's threshold +
  # household cooldown + multipliers + achievements (same path as a
  # user tap or an auto-mapper event).
  def complete(name_or_chore, timestamp = nil)
    chore = load_chore(name_or_chore)
    return nil if chore.nil?

    at = parse_time(timestamp) || Time.current
    result = ::ChoreCompleter.new(chore, @jil.user, at: at).call
    result.completion
  end

  # Chore.uncomplete("Vitamins") → destroy the most recent completion
  # by the current user for today's chore-day. Returns true if
  # something was destroyed.
  def uncomplete(name_or_chore)
    chore = load_chore(name_or_chore)
    return false if chore.nil?

    day = ChoreDay.current(@jil.user)
    completion = @jil.user.chore_completions
      .where(chore_id: chore.id, day_key: day)
      .order(completed_at: :desc).first
    return false if completion.nil?

    completion.destroy!
    true
  end

  # Chore.sync_event(name, event[, event_attrs]) → mirror an
  # ActionEvent's lifecycle as a ChoreCompletion. Uses metadata.source
  # = { type: "action_event", id: <event_id> } as the link.
  #
  #   * action :added / :changed — create the linked completion at the
  #     event's timestamp, or update an existing linked one. If no link
  #     exists but a same-day completion does, adopt it (no duplicate).
  #     If the event no longer matches `event_attrs`, unlink/destroy
  #     the previously linked completion (e.g. notes edited).
  #   * action :removed — destroy the linked completion (if any).
  #
  # `event_attrs` (optional Hash) — same shape used by sync_completion:
  # `{ name: <event name>, notes?: <event notes> }`. Both fields are
  # exact case-insensitive matches. Notes is treated as a constraint
  # only when present (a row that's `{name: "Wordle"}` matches Wordle
  # events with any notes). This shared shape lets one mapping table
  # drive both directions of sync.
  #
  # Returns true if a change was made.
  def sync_event(name_or_chore, event, event_attrs = nil)
    ae = load_action_event(event)
    return false if ae.nil? || ae.id.blank?

    chore = load_chore(name_or_chore)
    return false if chore.nil?

    action = ae.execution_attrs.is_a?(::Hash) ? ae.execution_attrs[:action] : nil
    matches = event_matches_attrs?(ae, event_attrs)

    case action&.to_sym
    when :added, :changed
      matches ? sync_upsert(chore, ae) : sync_remove(chore, ae)
    when :removed
      sync_remove(chore, ae)
    else false
    end
  end

  # Chore.sync_completion(name, completion, event_attrs) → mirror a
  # ChoreCompletion's lifecycle as an ActionEvent (the reverse of
  # sync_event). Signature is parallel to sync_event so the same
  # mapping table can drive both directions:
  #
  #   Chore.sync_event(name, event, event_attrs)
  #   Chore.sync_completion(name, completion, event_attrs)
  #
  # `name` is the chore name being synced (used as a dispatch filter —
  # we no-op when it doesn't match the completion's chore, so callers
  # can iterate a mapping table blindly). `completion` can be a
  # ChoreCompletion record (typical when called from a chore_completion
  # trigger) or a Hash with at least { id:, action:, completed_at:,
  # metadata:, chore_name: }. `event_attrs` is a Hash with required
  # `name` and optional `notes`. Link lives on the event:
  #   event.data.source = { type: "chore_completion", id: <comp_id> }
  #
  # Lifecycle (driven by completion.execution_attrs[:action]):
  #   :completed — skip if the completion was itself created from an
  #                event (metadata.source.type == "action_event") to
  #                avoid duplicating it; otherwise upsert.
  #   :edited    — find the linked event and upsert (timestamp + notes).
  #   :uncompleted — destroy the linked event (if any).
  #
  # Upsert is fully idempotent: when the existing event already matches
  # the desired state, no DB write happens. The corresponding `event
  # :changed` trigger never fires, so the bi-directional sync
  # self-terminates without explicit provenance flags.
  def sync_completion(name_or_chore, completion, event_attrs)
    comp_data = load_completion(completion)
    return false if comp_data.nil?
    return false unless completion_matches_chore?(comp_data, name_or_chore)

    action = comp_data[:action]&.to_sym
    return false if action.blank?

    case action
    when :uncompleted
      # Destroy doesn't need event_attrs — the link lives on the event itself.
      destroy_linked_event(comp_data)
    when :completed
      attrs = stringify_event_attrs(event_attrs)
      return false if attrs.blank? || attrs[:name].blank?
      return false if completion_from_event?(comp_data)

      upsert_event(comp_data, attrs)
    when :edited
      attrs = stringify_event_attrs(event_attrs)
      return false if attrs.blank? || attrs[:name].blank?

      upsert_event(comp_data, attrs)
    else
      false
    end
  end

  # Chore.balance → lifetime balance (pebbles earned - withdrawn).
  def balance
    @jil.user.chore_balance
  end

  # Chore.today_earnings → pebbles earned in today's chore-day.
  def today_earnings
    @jil.user.chore_balance_breakdown(ChoreDay.current(@jil.user))[:today_earnings]
  end

  private

  def find_by_id(id)
    @jil.user.accessible_chores.find_by(id: id)
  end

  def find_by_name(name)
    return nil if name.to_s.strip.empty?

    @jil.user.accessible_chores
      .where("chores.name ILIKE :q OR chores.short_name ILIKE :q", q: "%#{name}%")
      .first
  end

  def find_by_attrs(hash)
    hash = hash.with_indifferent_access
    id = hash[:id] || hash["id"]
    return find_by_id(id) if id

    find_by_name(hash[:name] || hash["name"])
  end

  def load_chore(value)
    return value if value.is_a?(::Chore)

    cast(value)
  end

  def parse_time(value)
    return nil if value.nil?
    return value if value.is_a?(Time) || value.is_a?(DateTime) || value.is_a?(Date)
    return Time.zone.at(value) if value.is_a?(Numeric)

    Time.zone.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def load_action_event(value)
    return nil if value.nil?
    return value if value.is_a?(::ActionEvent)
    return @jil.user.action_events.find_by(id: value) if value.is_a?(::Numeric)

    id = @jil.cast(value, :Hash)[:id]
    return nil if id.blank?

    @jil.user.action_events.find_by(id: id)
  end

  def sync_upsert(chore, ae)
    at = parse_time(ae.timestamp) || Time.current
    day = ChoreDay.current(@jil.user, at: at)

    linked = linked_completion(chore, ae)
    if linked
      linked.update!(completed_at: at, day_key: day)
      return true
    end

    same_day = @jil.user.chore_completions.find_by(chore_id: chore.id, day_key: day)
    if same_day
      same_day.update!(metadata: stamp_source(same_day.metadata, ae))
      return false
    end

    completion = ::ChoreCompleter.new(chore, @jil.user, at: at).call.completion
    completion.update!(metadata: stamp_source(completion.metadata, ae))
    true
  end

  def sync_remove(chore, ae)
    linked = linked_completion(chore, ae)
    return false if linked.nil?

    linked.destroy!
    true
  end

  def linked_completion(chore, ae)
    @jil.user.chore_completions
      .where(chore_id: chore.id)
      .where("metadata #>> '{source,type}' = ?", "action_event")
      .where("(metadata #>> '{source,id}')::bigint = ?", ae.id)
      .first
  end

  def stamp_source(existing, ae)
    (existing || {}).merge(source: { type: "action_event", id: ae.id })
  end

  def event_matches_attrs?(ae, event_attrs)
    return true if event_attrs.blank?

    attrs = stringify_event_attrs(event_attrs)
    return true if attrs.blank? || attrs[:name].blank?
    return false unless ae.name.to_s.casecmp(attrs[:name].to_s).zero?
    return true if attrs[:notes].blank?

    ae.notes.to_s.casecmp(attrs[:notes].to_s).zero?
  end

  # --- sync_completion helpers ---

  def load_completion(value)
    return nil if value.nil?

    if value.is_a?(::ChoreCompletion)
      attrs = value.execution_attrs.is_a?(::Hash) ? value.execution_attrs : {}
      return {
        id:           value.id,
        action:       attrs[:action],
        completed_at: value.completed_at,
        metadata:     value.metadata || {},
        chore_id:     value.chore_id,
        chore_name:   value.chore&.name,
      }
    end

    hash = @jil.cast(value, :Hash).with_indifferent_access
    chore_id = hash[:chore_id]
    chore_name = hash[:chore_name].presence
    chore_name ||= @jil.user.accessible_chores.find_by(id: chore_id)&.name if chore_id.present?

    {
      id:           hash[:id],
      action:       hash[:action]&.to_sym,
      completed_at: parse_time(hash[:completed_at]),
      metadata:     hash[:metadata] || {},
      chore_id:     chore_id,
      chore_name:   chore_name,
    }
  end

  def completion_matches_chore?(comp_data, name_or_chore)
    return true if name_or_chore.blank?

    expected = name_or_chore.is_a?(::Chore) ? name_or_chore.name : name_or_chore.to_s
    actual = comp_data[:chore_name].to_s
    return true if actual.blank? # fall back to no filter when we can't tell

    actual.casecmp(expected).zero?
  end

  def stringify_event_attrs(value)
    return {} if value.blank?

    @jil.cast(value, :Hash).with_indifferent_access.then { |h|
      {
        name:  h[:name].to_s.presence,
        notes: h[:notes].presence&.to_s,
      }
    }
  end

  def completion_from_event?(comp_data)
    comp_data.dig(:metadata, "source", "type").to_s == "action_event" ||
      comp_data.dig(:metadata, :source, :type).to_s == "action_event"
  end

  def find_linked_event(comp_id)
    return nil if comp_id.blank?

    @jil.user.action_events
      .where("data #>> '{source,type}' = ?", "chore_completion")
      .where("(data #>> '{source,id}')::bigint = ?", comp_id)
      .first
  end

  def upsert_event(comp_data, attrs)
    completed_at = comp_data[:completed_at]
    return false if completed_at.blank?

    existing = find_linked_event(comp_data[:id])
    desired = {
      name:      attrs[:name],
      notes:     attrs[:notes],
      timestamp: completed_at,
    }

    if existing
      return false if event_matches_desired?(existing, desired)

      existing.update!(desired.compact)
      true
    else
      data = { source: { type: "chore_completion", id: comp_data[:id] } }
      @jil.user.action_events.create!(desired.merge(data: data))
      true
    end
  end

  def destroy_linked_event(comp_data)
    existing = find_linked_event(comp_data[:id])
    return false if existing.nil?

    existing.destroy!
    true
  end

  def event_matches_desired?(event, desired)
    return false unless event.name.to_s == desired[:name].to_s
    return false unless event.notes.to_s == desired[:notes].to_s
    return false unless event.timestamp.present? && desired[:timestamp].present?
    return false unless (event.timestamp.to_i - desired[:timestamp].to_i).abs < 1

    true
  end
end

# [Chore]
#   #find(String)::Chore
#   #scheduled_today::Array
#   #accessible::Array
#   #complete(String:Name Date?:Timestamp)::ChoreCompletion
#   #uncomplete(String)::Boolean
#   #sync_event(String:"Chore Name" ActionEvent Hash?:"Event Attrs")::Boolean
#   #sync_completion(String:"Chore Name" Hash|ChoreCompletion Hash:"Event Attrs")::Boolean
#   #balance::Integer
#   #today_earnings::Integer
#
# Wiring an event → chore mapping is done in Jil itself. Two patterns:
#
#   * Targeted task per event: listener
#     `event name:food:vitamins action:added` calls `Chore.complete(...)`.
#   * Mapping task: listener `event` with a single hash of
#     ActionEvent.name → Chore.name. Call
#     `Chore.sync_event(map.get(event.name), event)` and it idempotently
#     handles added/changed/removed via the completion's
#     `metadata.source = { type: "action_event", id: <id> }` link.
#
# The Chore model fires `chore` / `chore_completion` triggers on its
# own lifecycle.
