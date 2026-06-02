# Jil bindings for the Chores system. Lets Jil tasks find chores,
# complete them, look up the user's balance, list today's chores, and
# wire ActionEvent names to auto-complete a chore (via ChoreEventMapping).
class Jil::Methods::Chore < Jil::Methods::Base
  PERMIT_ADD_ATTRS = [
    :name,
    :short_name,
    :icon,
    :sharing_mode,
    :one_off,
    :starts_on,
    :reward_pebbles,
    :assigned_to,
    :show_on_daily_view,
  ].freeze

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

  # Routes ChoreData hash-builder calls (used inside content(ChoreData) blocks)
  # to the builder methods below. Everything else falls through to the default
  # Ruby-method dispatch.
  def execute(line)
    method_sym = line.methodname.to_s.underscore.gsub(/[^\w]/, "").to_sym
    if token_class(line.objname) == :ChoreData && PERMIT_ADD_ATTRS.include?(method_sym)
      return send(method_sym, *evalargs(line.args))
    end

    fallback(line)
  end

  # Chore.find("Vitamins") → first chore whose name contains "Vitamins"
  # (case-insensitive). Scoped to the user's accessible set so household
  # chores resolve too.
  def find(name)
    find_by_name(name)
  end

  # Chore.add(content(ChoreData)) → create a new Chore owned by the running
  # user. ChoreData block lines build the attrs hash (`#name`, `#assigned_to`,
  # `#sharing_mode`, `#one_off`, `#starts_on`, `#reward_pebbles`, etc).
  # `assigned_to` accepts a User, username, id, or hash. `sharing_mode`
  # accepts the enum key as String/Symbol. Returns the new Chore record, or
  # nil if validation failed (e.g. blank name).
  def add(details)
    attrs = @jil.cast(details, :Hash).slice(*PERMIT_ADD_ATTRS)
    return nil if attrs[:name].to_s.strip.empty?

    household = ensure_household
    return nil if household.nil?

    assigned = load_user(attrs.delete(:assigned_to))
    sharing_key = attrs.delete(:sharing_mode).to_s.downcase.presence
    sharing = ::Chore.sharing_modes.key?(sharing_key) ? sharing_key.to_sym : :personal
    daily_key = attrs.delete(:show_on_daily_view).to_s.downcase.presence
    daily = ::Chore.show_on_daily_views.key?(daily_key) ? daily_key.to_sym : nil
    starts_on = parse_date(attrs.delete(:starts_on))

    chore = household.chores.create(
      attrs.merge(
        created_by_user_id:  @jil.user.id,
        sharing_mode:        sharing,
        assigned_to_user_id: assigned&.id,
        starts_on:           starts_on,
        show_on_daily_view:  daily,
      ).compact,
    )
    chore.persisted? ? chore : nil
  end

  def ensure_household
    existing = ::ChoreHouseholdMembership.where(user_id: @jil.user.id).first
    if existing
      @jil.user.reload if @jil.user.chore_household_id.nil?
      return existing.chore_household
    end

    household = ::ChoreHousehold.create!(
      owner_user: @jil.user,
      name: "#{@jil.user.display_name}'s Household",
    )
    @jil.user.reload
    household
  end

  # ---- [ChoreData] hash builders (used inside content(ChoreData) blocks) ----

  def name(text)
    { name: text }
  end

  def short_name(text)
    { short_name: text }
  end

  def icon(text)
    { icon: text }
  end

  def assigned_to(value)
    { assigned_to: value }
  end

  def sharing_mode(value)
    { sharing_mode: value }
  end

  def one_off(value)
    { one_off: @jil.cast(value, :Boolean) }
  end

  def starts_on(value)
    { starts_on: value }
  end

  def reward_pebbles(value)
    { reward_pebbles: @jil.cast(value, :Numeric).to_i }
  end

  def show_on_daily_view(value)
    { show_on_daily_view: value }
  end

  # Chore.scheduled_today → array of Chore records visible on Today.
  def scheduled_today
    ctx = ChoreSerializerContext.for_user(@jil.user)
    chore_ids = ctx.serialize_all(@jil.user.accessible_chores.to_a)
      .select { |c| c[:today_visible] }.pluck(:id)
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
  def complete(name_or_chore, timestamp=nil)
    chore = load_chore(name_or_chore)
    return nil if chore.nil?

    at = parse_time(timestamp) || Time.current
    result = ::ChoreCompleter.new(chore, @jil.user, at: at).call
    result.completion
  end

  # Chore.complete_for(name, username[, timestamp]) → run a completion on
  # behalf of another user (resolved via load_user). Mirrors `#complete`
  # but credits the chosen user with the pebbles. Returns the
  # ChoreCompletion, or nil if the chore or user couldn't be resolved.
  def complete_for(name_or_chore, as_user, timestamp=nil)
    chore = load_chore(name_or_chore)
    return nil if chore.nil?

    user = load_user(as_user)
    return nil if user.nil?

    at = parse_time(timestamp) || Time.current
    ::ChoreCompleter.new(chore, user, at: at).call.completion
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
  # ActionEvent's lifecycle as a ChoreCompletion. Partner matched by
  # chore_id + timestamp. `event_attrs` shape: `{name:, notes?:}`
  # (case-insensitive; notes is a constraint only when present).
  # On :changed, `execution_attrs[:changes][:timestamp][0]` provides the
  # OLD time so the partner can be located before moving.
  def sync_event(name_or_chore, event, event_attrs=nil)
    ae = load_action_event(event)
    return false if ae.nil? || ae.id.blank?

    chore = load_chore(name_or_chore)
    return false if chore.nil?

    exec_attrs = ae.execution_attrs.is_a?(::Hash) ? ae.execution_attrs : {}
    action = exec_attrs[:action]&.to_sym
    matches = event_matches_attrs?(ae, event_attrs)

    case action
    when :added
      matches ? upsert_completion(chore, ae, prev_at: nil) : false
    when :changed
      prev_at = parse_time(dig_change(exec_attrs, :timestamp))
      if matches
        upsert_completion(chore, ae, prev_at: prev_at)
      else
        destroy_completion_partner(chore, prev_at || parse_time(ae.timestamp))
      end
    when :removed
      destroy_completion_partner(chore, parse_time(ae.timestamp))
    else false
    end
  end

  # Chore.sync_completion(name, completion, event_attrs) → reverse of
  # sync_event. Partner event located via event_attrs (from the mapping)
  # + completed_at. On :edited, `comp_data[:changes][:completed_at][0]`
  # is the OLD time.
  def sync_completion(name_or_chore, completion, event_attrs)
    comp_data = load_completion(completion)
    return false if comp_data.nil?
    return false unless completion_matches_chore?(comp_data, name_or_chore)

    action = comp_data[:action]&.to_sym
    return false if action.blank?

    attrs = stringify_event_attrs(event_attrs)
    return false if attrs.blank? || attrs[:name].blank?

    case action
    when :uncompleted
      destroy_event_partner(attrs, comp_data[:completed_at])
    when :completed
      upsert_event(comp_data, attrs, prev_at: nil)
    when :edited
      prev_at = parse_time(dig_change(comp_data, :completed_at))
      upsert_event(comp_data, attrs, prev_at: prev_at)
    else
      false
    end
  end

  # Chore.balance → lifetime balance (pebbles earned + received -
  # withdrawn - sent).
  def balance
    @jil.user.chore_balance
  end

  # Chore.today_earnings → pebbles earned in today's chore-day.
  def today_earnings
    @jil.user.chore_balance_breakdown(ChoreDay.current(@jil.user))[:today_earnings]
  end

  # Chore.withdraw(amount[, note]) → record a ChoreWithdrawal. Returns
  # the new record, or nil if validation failed (amount must be > 0).
  def withdraw(amount, note=nil)
    n = amount.to_i
    return nil if n <= 0

    @jil.user.chore_withdrawals.create(amount_pebbles: n, note: note.to_s.presence)
      &.then { |w| w.persisted? ? w : nil }
  end

  # Chore.transfer(amount, recipient[, note]) → record a ChoreTransfer
  # from the running user to the recipient. `recipient` may be a User,
  # a numeric user_id, a String username, or a Hash with `id` /
  # `username`. Returns the new record, or nil if validation failed
  # (recipient must be in the user's chore household, amount must fit).
  def transfer(amount, recipient, note=nil)
    n = amount.to_i
    return nil if n <= 0

    to_user = load_user(recipient)
    return nil if to_user.nil?

    record = @jil.user.chore_transfers_sent.create(
      to_user: to_user, amount_pebbles: n, note: note.to_s.presence,
    )
    record.persisted? ? record : nil
  end

  # Chore.history(q, limit, order) → interleaved completion +
  # withdrawal + transfer log. Same signature as ActionEvent.search /
  # Email.search:
  #   * `q`     — Tokenizing query string. Same syntax the History
  #               page uses: `notes:foo`, `time>2026-05-01`,
  #               `amount>1`, `name:Cat`, free keywords. Applied
  #               independently to each feed via the model's own
  #               search_terms config; tokens that don't apply to
  #               one feed (e.g. `name:` doesn't exist on transfers)
  #               just leave that feed unfiltered.
  #   * `limit` — defaults to 50, clamped to 1..100 (matching the
  #               other Jil index endpoints).
  #   * `order` — `:asc` or `:desc` (default `:desc`).
  #
  # Returns an Array of Hashes — each with `:kind`
  # ("completion" | "withdrawal" | "transfer") plus the same fields
  # the UI's recent-history feed uses, so the three heterogeneous
  # feeds can be iterated in one pass.
  def history(q, limit, order)
    limit = (limit.presence || 50).to_i.clamp(1..100)
    direction = [:asc, :desc].include?(order.to_s.downcase.to_sym) ? order.to_s.downcase.to_sym : :desc

    completions = scoped_for(ChoreCompletion, q, limit, :completed_at, direction)
      .where(user: @jil.user)
      .includes(:chore)
    withdrawals = scoped_for(ChoreWithdrawal, q, limit, :created_at, direction)
      .where(user: @jil.user)
    transfers   = scoped_for(ChoreTransfer, q, limit, :created_at, direction)
      .where("from_user_id = :id OR to_user_id = :id", id: @jil.user.id)
      .includes(:from_user, :to_user)

    sorter = ->(e) { e.is_a?(ChoreCompletion) ? e.completed_at : e.created_at }
    merged = (completions.to_a + withdrawals.to_a + transfers.to_a).sort_by(&sorter)
    merged.reverse! if direction == :desc
    merged.first(limit).map { |e| history_entry_hash(e) }
  end

  private

  def history_entry_hash(entry)
    case entry
    when ChoreCompletion
      {
        kind:           "completion",
        id:             entry.id,
        chore_id:       entry.chore_id,
        chore_name:     entry.chore&.name,
        paid_pebbles:   entry.paid_pebbles,
        base_pebbles:   entry.base_pebbles,
        note:           entry.note.to_s,
        completed_at:   entry.completed_at&.iso8601(3),
        payout_skipped: entry.payout_skipped,
        skipped_reason: entry.skipped_reason,
      }
    when ChoreWithdrawal
      {
        kind:           "withdrawal",
        id:             entry.id,
        amount_pebbles: entry.amount_pebbles,
        note:           entry.note.to_s,
        created_at:     entry.created_at&.iso8601(3),
      }
    when ChoreTransfer
      outgoing = entry.from_user_id == @jil.user.id
      counterparty = outgoing ? entry.to_user : entry.from_user
      {
        kind:                  "transfer",
        id:                    entry.id,
        direction:             outgoing ? "outgoing" : "incoming",
        amount_pebbles:        entry.amount_pebbles,
        counterparty_username: counterparty&.username,
        from_user_id:          entry.from_user_id,
        to_user_id:            entry.to_user_id,
        note:                  entry.note.to_s,
        created_at:            entry.created_at&.iso8601(3),
      }
    end
  end

  # Run the `.query` scope (which uses each model's `search_terms`
  # config) then apply page+limit+order, mirroring the shape of
  # ActionEvent.search / Email.search but on a model class rather
  # than a relation. `.query` deliberately clears prior scoping per
  # ApplicationRecord, so the caller re-applies the user filter on
  # the returned relation.
  def scoped_for(klass, q, limit, ts_column, direction)
    base = q.present? ? klass.query(q) : klass.all
    base.page(1).per(limit).order(ts_column => direction)
  rescue StandardError => e
    Rails.logger.warn("Chore.history query failed for #{klass}: #{e.message}")
    klass.order(ts_column => direction).limit(limit)
  end

  def load_user(value)
    return nil if value.nil?
    return value if value.is_a?(::User)
    return ::User.find_by(id: value) if value.is_a?(::Numeric)

    if value.is_a?(::String)
      uname = value.strip
      return nil if uname.empty?

      return ::User.find_by(username: uname)
    end

    hash = @jil.cast(value, :Hash)
    return ::User.find_by(id: hash[:id]) if hash[:id].present?
    return ::User.find_by(username: hash[:username]) if hash[:username].present?

    nil
  end

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

  def parse_date(value)
    return nil if value.blank?
    return value if value.is_a?(Date)
    return value.to_date if value.is_a?(Time) || value.is_a?(DateTime)

    parse_time(value)&.to_date
  end

  def load_action_event(value)
    return nil if value.nil?
    return value if value.is_a?(::ActionEvent)
    return @jil.user.action_events.find_by(id: value) if value.is_a?(::Numeric)

    id = @jil.cast(value, :Hash)[:id]
    return nil if id.blank?

    @jil.user.action_events.find_by(id: id)
  end

  def upsert_completion(chore, ae, prev_at: nil)
    at = parse_time(ae.timestamp) || Time.current
    day = ChoreDay.current(@jil.user, at: at)
    note = ae.notes.to_s.presence

    partner = find_completion_partner(chore, prev_at) || find_completion_partner(chore, at)
    if partner
      desired = { completed_at: at, day_key: day, note: note }
      return false if completion_matches_desired?(partner, desired)

      partner.update!(desired.compact)
      return true
    end

    completion = ::ChoreCompleter.new(chore, @jil.user, at: at).call.completion
    completion.update!(note: note) if note.present? && completion&.note.to_s != note
    true
  end

  def destroy_completion_partner(chore, at)
    partner = find_completion_partner(chore, at)
    return false if partner.nil?

    partner.destroy!
    true
  end

  def find_completion_partner(chore, at)
    return nil if chore.nil? || at.blank?

    @jil.user.chore_completions
      .where(chore_id: chore.id)
      .where(completed_at: (at - 1.second)..(at + 1.second))
      .order(:completed_at)
      .first
  end

  def completion_matches_desired?(comp, desired)
    return false unless comp.completed_at.present? && desired[:completed_at].present?
    return false unless (comp.completed_at.to_i - desired[:completed_at].to_i).abs < 1
    return false unless comp.note.to_s == desired[:note].to_s

    true
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
        changes:      attrs[:changes] || {},
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
      changes:      hash[:changes] || {},
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

  def find_event_partner(attrs, at)
    return nil if attrs[:name].blank? || at.blank?

    scope = @jil.user.action_events
      .where("LOWER(action_events.name) = ?", attrs[:name].to_s.downcase)
      .where(timestamp: (at - 1.second)..(at + 1.second))
    scope = scope.where("LOWER(action_events.notes) = ?", attrs[:notes].to_s.downcase) if attrs[:notes].present?
    scope.order(:timestamp).first
  end

  def upsert_event(comp_data, attrs, prev_at: nil)
    completed_at = comp_data[:completed_at]
    return false if completed_at.blank?

    partner = find_event_partner(attrs, prev_at) || find_event_partner(attrs, completed_at)
    desired = {
      name:      attrs[:name],
      notes:     attrs[:notes],
      timestamp: completed_at,
    }

    if partner
      return false if event_matches_desired?(partner, desired)

      partner.update!(desired.compact)
    else
      @jil.user.action_events.create!(desired.compact)
    end
    true
  end

  def destroy_event_partner(attrs, at)
    partner = find_event_partner(attrs, at)
    return false if partner.nil?

    partner.destroy!
    true
  end

  def event_matches_desired?(event, desired)
    return false unless event.name.to_s.casecmp(desired[:name].to_s).zero?
    return false if desired[:notes].present? && !event.notes.to_s.casecmp(desired[:notes].to_s).zero?
    return false unless event.timestamp.present? && desired[:timestamp].present?
    return false unless (event.timestamp.to_i - desired[:timestamp].to_i).abs < 1

    true
  end

  # Read `[old, new]` from either a saved_changes-style hash on
  # execution_attrs[:changes] (string keys) or the same shape on a
  # loaded completion data hash (symbol keys).
  def dig_change(holder, field)
    changes = holder[:changes] || holder["changes"]
    return nil if changes.blank?

    pair = changes[field.to_s] || changes[field.to_sym]
    pair.is_a?(::Array) ? pair[0] : nil
  end
end

# [Chore]
#   #find(String)::Chore
#   #scheduled_today::Array
#   #accessible::Array
#   #add(content(ChoreData))::Chore
#   #complete(String:Name Date?:Timestamp)::ChoreCompletion
#   #complete_for(String:Name String:"Username" Date?:Timestamp)::ChoreCompletion
#   #uncomplete(String)::Boolean
#   #sync_event(String:"Chore Name" ActionEvent Hash?:"Event Attrs")::Boolean
#   #sync_completion(String:"Chore Name" Hash|ChoreCompletion Hash:"Event Attrs")::Boolean
#   #balance::Integer
#   #today_earnings::Integer
#   #withdraw(Integer:Amount String?:Note)::ChoreWithdrawal
#   #transfer(Integer:Amount User|String|Integer:Recipient String?:Note)::ChoreTransfer
#   #history(String?:Query Integer?:Limit String?:Order)::Array
#     # Same Tokenizing syntax as the History page:
#     #   amount>1                   numeric comparison
#     #   notes:foo / time>2026-05   text + date filters
#     #   name:Cat                   joined chore.name filter
#     # Order: "asc" | "desc" (default desc), limit capped at 500.
#
# Triggers fired by these endpoints (listen for them in Jil tasks):
#   * `chore_withdrawal action:created|updated|destroyed`
#   * `chore_transfer  action:created|updated|destroyed direction:outgoing|incoming`
#     (the transfer trigger fires once for the sender and once for the
#      recipient — each with their own direction).
#
# Wiring an event → chore mapping is done in Jil itself. Two patterns:
#
#   * Targeted task per event: listener
#     `event name:food:vitamins action:added` calls `Chore.complete(...)`.
#   * Mapping task: listener `event` with a single hash of
#     ActionEvent.name → Chore.name. Call
#     `Chore.sync_event(choreName, event, eventAttrs)` and it idempotently
#     handles added/changed/removed.
#
# The Chore model fires `chore` / `chore_completion` triggers on its
# own lifecycle.
#
# *[ChoreData]
#   #name(String)
#   #short_name(String)
#   #icon(String)
#   #assigned_to(String|User|Numeric|Hash)
#   #sharing_mode(["personal" "household"])
#   #one_off(Boolean)
#   #starts_on(Date)
#   #reward_pebbles(Numeric)
#   #show_on_daily_view(["always" "when_scheduled" "when_available" "when_scheduled_and_available" "never"])
