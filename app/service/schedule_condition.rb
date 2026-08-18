# A truthy check that a scheduled thing carries and answers at FIRE time.
#
# "Charge the village car if the chore isn't done yet" used to be three
# reminders an hour apart whose `if` was decorative: a BuddyReminder renders its
# body and posts it, so the condition was a sentence the person read rather than
# anything the app evaluated. All three arrived whether or not the car got
# charged.
#
# Two kinds, and neither knows anything about chores:
#
#   SEARCH — does anything match, in the breaker syntax the whole app already
#   searches with (`Tokenizing::Node` -> `ApplicationRecord#query_by_node`):
#
#     { kind: :search, find: :action_events, query: 'name:"Workout" is:today',
#       expect: :missing }
#
#   JIL — run one of their own function tasks and read what it says. Anything
#   they can wire, they can gate a schedule on: a sensor, a device, an API, a
#   calculation:
#
#     { kind: :jil, task: "Is The Car Plugged In", expect: :truthy }
#
# `expect` is the polarity and both directions of each are real: skip the nudge
# once the thing is DONE (`missing`), or hold it until it HAS happened
# (`found`); fire while a sensor says yes (`truthy`), or while it says no.
#
# Three things this deliberately does NOT do:
#
#   * It doesn't call `Model.query`. That scope is documented as dropping the
#     current relation - "This will lose user filtering!!!" - so a condition
#     built on it would answer about the whole database. It follows
#     ChoresController#safe_query instead: build the SQL fragment from the
#     breaker, then apply it to a base scope this file controls, which is where
#     the joins and the ownership live.
#   * It doesn't accept an arbitrary model name. `SETS` is a whitelist, and each
#     entry supplies its own base scope, because "which rows can this person ask
#     about" is not a question the search syntax can answer.
#   * It doesn't store a resolved task id for the Jil kind. The name re-resolves
#     on every run, the same way a routine step and a reminder `command` do, so
#     renaming a task degrades to an unanswerable condition rather than quietly
#     running the nearest thing to it.
module ScheduleCondition
  module_function

  # What a condition may search, and the rows it may search within.
  #
  # Household rather than user for anything chore-shaped: a chore the house
  # shares is done when ANYONE does it, so "is it done yet" scoped to one person
  # would nag whoever didn't happen to be the one who did it. Falls back to the
  # person's own rows when they're in no household, since an empty
  # `chore_household_id` would otherwise match every householdless row.
  SETS = {
    action_events:     ->(user) { ActionEvent.where(user_id: user.id) },
    # A SUBQUERY rather than a join, and that's load-bearing. The fragment is
    # built against `AgendaItem.unscoped`, so its free-text half says bare
    # `name` — and `agendas` has a `name` column too, so joining the base scope
    # makes every plain query ambiguous in SQL. Only join here when the search
    # terms actually reach across (chore_completions, below, whose `name:` IS
    # `chores.name`).
    agenda_items:      ->(user) { AgendaItem.where(agenda_id: Agenda.where(user_id: user.id).select(:id)) },
    chore_completions: ->(user) {
      base = ChoreCompletion.joins(:chore)
      household = user.chore_household_id
      household ? base.where(chores: { chore_household_id: household }) : base.where(user_id: user.id)
    },
    chores:            ->(user) {
      household = user.chore_household_id
      household ? Chore.where(chore_household_id: household) : Chore.where(created_by_user_id: user.id)
    },
    emails:            ->(user) { Email.where(user_id: user.id) },
    contacts:          ->(user) { Contact.where(user_id: user.id) },
    boxes:             ->(user) { Box.where(user_id: user.id) },
  }.freeze

  KINDS   = %i[search jil].freeze
  EXPECTS = { search: %i[found missing], jil: %i[truthy falsy] }.freeze

  # What a Jil function has to come back with to count as NO. Everything else,
  # including a number, a name or a sentence, is yes.
  #
  # Blank is false because a task that returns nothing has reported nothing, and
  # "no answer" must never read as "yes, go ahead" - that's the direction that
  # fires things nobody asked for.
  FALSY = ["", "false", "0", "no", "nil", "null", "off", "none", "unknown"].freeze

  def sets  = SETS.keys
  def kinds = KINDS

  # No condition is not a failed condition. Everything that has never carried
  # one has to keep firing exactly as it did.
  def present?(condition)
    normalize(condition).present?
  end

  # True when the thing should go ahead.
  #
  # Raises rather than guessing: an unknown set, a missing query, a task that
  # doesn't resolve are all authoring mistakes, and a condition that silently
  # reads as "yes" is a schedule that fires forever while looking like it's
  # being checked. Callers decide what an unanswerable check means for them -
  # see ReminderFirer, which fires anyway and says so.
  #
  # Evaluated inside the person's own timezone, because a relative window is a
  # question about their day. `is:today` resolves through ChoreDay, which reads
  # `Time.zone` when it isn't handed a user - and a query-syntax scope is called
  # as `search_scope.send(:is_search, value)`, so there is nowhere to hand it
  # one. The app sets no `config.time_zone`, so without this the boundary lands
  # on UTC's 4am and a chore ticked off at 11pm belongs to tomorrow.
  def met?(condition, user:)
    data = normalize(condition)
    return true if data.blank?

    user.timezone { answer(data, user) }
  end

  def answer(data, user)
    case data[:kind]
    when :search
      exists = matches(data, user).exists?
      data[:expect] == :missing ? !exists : exists
    when :jil
      truthy = truthy?(ran(data, user))
      data[:expect] == :falsy ? !truthy : truthy
    end
  end

  # ---- the search kind -----------------------------------------------------

  # The matching rows themselves, for anything that wants to say WHY.
  def matches(data, user)
    scope = SETS.fetch(data[:find]).call(user)
    node  = ::Tokenizing::Node.parse(data[:query])
    sql   = scope.klass.unscoped.query_by_node(node).stripped_sql
    raise "condition query #{data[:query].inspect} matched nothing parseable" if sql.blank?

    scope.where(sql)
  end

  # ---- the jil kind --------------------------------------------------------

  # Runs the function and returns whatever it said, as a string.
  #
  # Same resolution `call_jil_function` uses, so a condition can only name a
  # function the person has actually shared with Buddy - a schedule is not a
  # back door to every task on the account.
  def ran(data, user)
    task = resolve_task(data[:task], user)
    args = (data[:args] || {}).transform_keys(&:to_s)
    # Signature order, not key order - `condition` is a jsonb column and comes
    # back sorted by key length. Same reasoning as call_jil_function.
    input = args.empty? ? {} : args.merge("params" => task.function_params(args))

    execution = task.execute(input, auth: :buddy, auth_id: user.id, trigger_scope: "buddy")
    execution.respond_to?(:result) ? execution.result.to_s : ""
  end

  def resolve_task(name, user)
    wanted = name.to_s.downcase.strip
    scope  = user.accessible_tasks.buddy_visible.functions
    found = scope.detect { |t| t.name.downcase == wanted }
    found ||= scope.detect { |t| t.name.downcase.start_with?(wanted) }
    found ||= scope.detect { |t| t.name.downcase.include?(wanted) }
    raise "no Jil function matches #{name.inspect}" if found.nil?

    found
  end

  def truthy?(result)
    FALSY.exclude?(result.to_s.strip.downcase)
  end

  # ---- storing + explaining ------------------------------------------------

  # Storable form: symbol keys, validated, or nil for "no condition".
  #
  # Runs on the way IN as well as on the way out, so a condition that can never
  # be evaluated is refused while the person is still in the conversation rather
  # than at 9pm three weeks later.
  def normalize(condition)
    data = (condition.presence || {}).to_h.symbolize_keys
    return nil if data.values_at(:find, :query, :task).all?(&:blank?)

    kind = (data[:kind].presence || (data[:task].present? ? :jil : :search)).to_s.to_sym
    raise "no condition kind called #{kind.inspect} (have: #{KINDS.join(", ")})" unless KINDS.include?(kind)

    send(:"normalize_#{kind}", data).merge(kind: kind, expect: expect_for(kind, data))
  end

  def expect_for(kind, data)
    allowed = EXPECTS.fetch(kind)
    given   = (data[:expect].presence || allowed.first).to_s.to_sym
    raise "a #{kind} condition expects #{allowed.join(" or ")}, not #{given.inspect}" unless allowed.include?(given)

    given
  end

  def normalize_search(data)
    find = data[:find].to_s.to_sym
    raise "no condition set called #{find.inspect} (have: #{sets.join(", ")})" unless SETS.key?(find)
    raise "a condition needs a query to search #{find} with" if data[:query].blank?

    { find: find, query: data[:query].to_s.strip }
  end

  def normalize_jil(data)
    raise "a jil condition needs the name of a function to call" if data[:task].blank?

    { task: data[:task].to_s.strip, args: (data[:args].presence || {}).to_h }
  end

  # One line for a person: what this is waiting on, in the order they'd say it.
  def describe(condition)
    data = normalize(condition)
    return nil if data.blank?

    case data[:kind]
    when :search
      "only if #{data[:expect] == :missing ? "no" : "any"} #{data[:find].to_s.humanize.downcase} match `#{data[:query]}`"
    when :jil
      "only if **#{data[:task]}** comes back #{data[:expect] == :falsy ? "false" : "true"}"
    end
  rescue StandardError => e
    "condition unreadable (#{e.message})"
  end

  # A skip is invisible by design - nothing is posted, which is the point - and
  # invisible is exactly how a condition that's quietly wrong stays wrong. So a
  # skipped fire leaves the same small pill any other tool leaves, with what was
  # checked on it.
  #
  # Deliberately NOT a message: `buddy_activity` is dropped by both the unread
  # count and the push path, so a chip explains a silence without breaking it.
  def announce_skip!(user:, conversation:, condition:, subject:)
    return if conversation.nil?

    Buddy::ActivityChip.post!(
      conversation: conversation,
      user:         user,
      tool_name:    :schedule_condition,
      ok:           false,
      body:         "Skipped **#{subject}**",
      detail:       describe(condition),
      payload:      normalize(condition).to_h.transform_keys(&:to_s),
    )
  rescue StandardError => e
    Rails.logger.warn("[ScheduleCondition] skip chip failed: #{e.class}: #{e.message}")
    nil
  end
end
