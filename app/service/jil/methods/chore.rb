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
end

# [Chore]
#   #find(String)::Chore
#   #scheduled_today::Array
#   #accessible::Array
#   #complete(String)::ChoreCompletion
#   #complete(String, String:timestamp)::ChoreCompletion
#   #uncomplete(String)::Boolean
#   #balance::Integer
#   #today_earnings::Integer
#
# Wiring an event → chore mapping is done in Jil itself: write a task
# with listener `event name:food:vitamins action:added` whose body calls
# `Chore.complete("Vitamins")`. The Chore model fires `chore` /
# `chore_completion` triggers on its own lifecycle.
