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

  # Chore.sync_event(name, event[, query]) → mirror an ActionEvent's
  # lifecycle as a ChoreCompletion. Uses metadata.source = {
  # type: "action_event", id: <event_id> } as the link so future
  # change/remove triggers find the right completion.
  #
  #   * action :added / :changed — create the linked completion at the
  #     event's timestamp, or update an existing linked one. If no link
  #     exists but a same-day completion does, adopt it (no duplicate).
  #     If the event no longer matches `query`, unlink/destroy the
  #     previously linked completion (e.g. notes edited to drop the
  #     training marker).
  #   * action :removed — destroy the linked completion (if any).
  #
  # `query` (optional String) — a Tokenizing search query such as
  # `"name::Whisper notes::Up"` or `"name::Wordle"`. Evaluated against
  # the event via the same parser that powers `.query()` on the model,
  # so it supports AND/OR/NOT/regex/exact/substring operators.
  # When blank, the chore is synced unconditionally on every event
  # (only useful if callers pre-filter via the listener).
  #
  # Returns true if a change was made.
  def sync_event(name_or_chore, event, query = nil)
    ae = load_action_event(event)
    return false if ae.nil? || ae.id.blank?

    chore = load_chore(name_or_chore)
    return false if chore.nil?

    action = ae.execution_attrs.is_a?(::Hash) ? ae.execution_attrs[:action] : nil
    matches = event_matches_query?(ae, query)

    case action&.to_sym
    when :added, :changed
      matches ? sync_upsert(chore, ae) : sync_remove(chore, ae)
    when :removed
      sync_remove(chore, ae)
    else false
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

  def event_matches_query?(ae, query)
    return true if query.to_s.blank?

    @jil.user.action_events.query(query.to_s).where(id: ae.id).exists?
  rescue StandardError => e
    Rails.logger.error("[Chore.sync_event] query failed (#{query.inspect}): #{e.class} #{e.message}")
    false
  end
end

# [Chore]
#   #find(String)::Chore
#   #scheduled_today::Array
#   #accessible::Array
#   #complete(String)::ChoreCompletion
#   #complete(String, String:timestamp)::ChoreCompletion
#   #uncomplete(String)::Boolean
#   #sync_event(String:"Chore Name" ActionEvent String?:"Query")::Boolean
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
