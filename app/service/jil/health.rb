# What is wrong with a person's automations right now, in four buckets:
#
#   failing - runs that errored inside FAILING_WINDOW
#   silent  - enabled tasks that stopped running relative to their own cadence
#   noisy   - tasks running far above their own trailing daily rate
#   orphans - trigger scopes seen on the bus that no enabled task listens to
#
# Every executions query is bounded by LOOKBACK and grouped by task, so the cost
# is one aggregate over a month of rows for the tasks in view, plus one
# DISTINCT ON for the latest failure of each failing task.
class Jil::Health
  LOOKBACK = 30.days
  FAILING_WINDOW = 7.days
  ORPHAN_WINDOW = 7.days
  NOISY_WINDOW = 24.hours
  # Trailing days the noisy rate is compared against, ending where the 24h
  # window starts.
  BASELINE_DAYS = 14
  # Below this many runs in a day nothing is noisy, however quiet it usually is.
  NOISY_MIN_RUNS = 20
  NOISY_FACTOR = 3
  # A listener task needs this many runs in LOOKBACK before its gaps say
  # anything about how often it should fire.
  CADENCE_MIN_RUNS = 3
  SILENT_FACTOR = 3
  SILENT_MIN_GAP = 1.day
  # A task that has never run is only silent once it has had time to.
  NEVER_RUN_GRACE = 7.days
  # The columns of one `stats` row, in the order the aggregate plucks them.
  STAT_KEYS = %i[
    run_count
    first_run_at
    last_run_at
    recent_count
    baseline_count
    failed_count
    last_failed_at
    last_success_at
  ].freeze
  # An anchor (`sun:sunset-5m`) has no fixed period; it resolves once a day.
  ANCHOR_INTERVAL = 1.day

  Failing = Struct.new(:task, :failed_count, :last_failed_at, :execution_id, :error, :recovered, keyword_init: true) {
    def at = last_failed_at
  }
  # `reason` is :cron (behind its schedule), :unschedulable (has a cron that
  # resolves to no next time), :cadence (quiet well past its usual gap) or
  # :never (has a listener and has never run).
  Silent = Struct.new(:task, :reason, :last_run_at, :expected_every, :at, keyword_init: true)
  Noisy = Struct.new(:task, :recent_count, :daily_average, :last_run_at, keyword_init: true) {
    def at = last_run_at
  }
  Orphan = Struct.new(:scope, :user, :last_seen_at, keyword_init: true) {
    def at = last_seen_at
  }

  attr_reader :user, :view_scope, :now

  def self.call(...) = new(...)

  def initialize(user, view_scope: :mine, now: Time.current)
    @user = user
    @view_scope = view_scope.to_sym == :all ? :all : :mine
    @now = now
  end

  def tasks
    @tasks ||= (
      scope = Task.active.enabled.includes(:user)
      scope = scope.where(id: user.accessible_tasks.pluck(:id)) if view_scope == :mine
      scope.to_a
    )
  end

  def failing
    @failing ||= (
      rows = stats.select { |_id, row| row[:failed_count].positive? }
      latest = latest_failures(rows.keys)
      rows.map { |task_id, row|
        execution = latest[task_id]
        Failing.new(
          task:           task_lookup[task_id],
          failed_count:   row[:failed_count],
          last_failed_at: row[:last_failed_at],
          execution_id:   execution&.id,
          error:          execution&.error,
          recovered:      row[:last_success_at].present? && row[:last_success_at] > row[:last_failed_at],
        )
      }.sort_by { |item| -item.at.to_f }
    )
  end

  def silent
    @silent ||= tasks.filter_map { |task| silent_entry(task) }.sort_by { |item| -item.at.to_f }
  end

  def noisy
    @noisy ||= tasks.filter_map { |task|
      row = stats[task.id]
      next if row.nil? || row[:recent_count] < NOISY_MIN_RUNS

      average = row[:baseline_count].to_f / BASELINE_DAYS
      next if row[:recent_count] < NOISY_FACTOR * [average, 1].max

      Noisy.new(
        task:          task,
        recent_count:  row[:recent_count],
        daily_average: average.round(1),
        last_run_at:   row[:last_run_at],
      )
    }.sort_by { |item| -item.at.to_f }
  end

  def orphans
    @orphans ||= (
      shapes = JilTriggerShape.where(last_seen_at: (now - ORPHAN_WINDOW)..).includes(:user)
      shapes = shapes.where(user_id: user.id) if view_scope == :mine
      shapes.to_a.reject { |shape| heard?(shape.user_id, shape.scope) }.map { |shape|
        Orphan.new(scope: shape.scope, user: shape.user, last_seen_at: shape.last_seen_at)
      }.sort_by { |item| -item.at.to_f }
    )
  end

  def problem_count
    failing.size + silent.size + noisy.size + orphans.size
  end

  # Seconds between expected runs for a cron string, the shortest of its
  # `|`-separated pieces. nil when no piece is readable.
  def self.cron_interval(cron)
    cron.to_s.split(/\s*\|\s*/).filter_map { |piece|
      next ANCHOR_INTERVAL.to_i if ::AnchorExpression.parse(piece)

      ::Fugit::Cron.parse(piece)&.rough_frequency
    }.min
  end

  private

  def task_lookup
    @task_lookup ||= tasks.index_by(&:id)
  end

  def silent_entry(task)
    return cron_silent(task) if task.cron.present?
    return if task.listener.blank? || task.function?

    listener_silent(task)
  end

  def cron_silent(task)
    interval = self.class.cron_interval(task.cron)
    last_run = task.last_trigger_at
    if interval.nil? || task.next_trigger_at.nil?
      return Silent.new(task: task, reason: :unschedulable, last_run_at: last_run, at: last_run || task.created_at)
    end

    allowed = [interval * 2, interval + 30.minutes.to_i].max
    since = last_run || task.created_at
    return if since + allowed > now

    Silent.new(
      task: task, reason: :cron, last_run_at: last_run, expected_every: interval, at: since + allowed,
    )
  end

  def listener_silent(task)
    last_run = task.last_trigger_at
    if last_run.nil?
      return if task.created_at + NEVER_RUN_GRACE > now

      return Silent.new(task: task, reason: :never, at: task.created_at + NEVER_RUN_GRACE)
    end

    row = stats[task.id]
    return if row.nil? || row[:run_count] < CADENCE_MIN_RUNS

    gap = (row[:last_run_at] - row[:first_run_at]) / (row[:run_count] - 1)
    allowed = [gap * SILENT_FACTOR, SILENT_MIN_GAP.to_i].max
    return if last_run + allowed > now

    Silent.new(
      task: task, reason: :cadence, last_run_at: last_run, expected_every: gap.round, at: last_run + allowed,
    )
  end

  # One grouped pass over LOOKBACK for every task in view.
  def stats
    return @stats if defined?(@stats)
    return @stats = {} if tasks.empty?

    @stats = (
      failed = Execution.statuses[:failed]
      success = Execution.statuses[:success]
      recent_from = now - NOISY_WINDOW
      baseline_from = recent_from - BASELINE_DAYS.days
      failing_from = now - FAILING_WINDOW
      rows = Execution.where(task_id: tasks.map(&:id), started_at: (now - LOOKBACK)..now).group(:task_id).pluck(
        :task_id,
        Arel.sql("COUNT(*)"),
        Arel.sql("MIN(started_at)"),
        Arel.sql("MAX(started_at)"),
        sql("COUNT(*) FILTER (WHERE started_at >= ?)", recent_from),
        sql("COUNT(*) FILTER (WHERE started_at >= ? AND started_at < ?)", baseline_from, recent_from),
        sql("COUNT(*) FILTER (WHERE status = ? AND started_at >= ?)", failed, failing_from),
        sql("MAX(started_at) FILTER (WHERE status = ? AND started_at >= ?)", failed, failing_from),
        sql("MAX(started_at) FILTER (WHERE status = ?)", success),
      )
      rows.to_h { |task_id, *values| [task_id, STAT_KEYS.zip(values).to_h] }
    )
  end

  def latest_failures(task_ids)
    return {} if task_ids.empty?

    scope = Execution.failed.where(task_id: task_ids, started_at: (now - FAILING_WINDOW)..now)
    scope = scope.select("DISTINCT ON (task_id) executions.*").order(:task_id, started_at: :desc)
    scope.includes(:payload).index_by(&:task_id)
  end

  def sql(fragment, *binds)
    Arel.sql(ActiveRecord::Base.sanitize_sql_array([fragment, *binds]))
  end

  # Mirrors Task.by_listener: a trigger reaches a task when any token of the
  # listener starts with the scope. A trigger is matched against the tasks
  # accessible to the person it fired for, and Buddy watches ride the same bus.
  def heard?(user_id, scope)
    pattern = /(^|\s)#{Regexp.escape(scope)}(~|:|$)/i
    listeners_by_user[user_id].to_a.any? { |listener| listener.match?(pattern) } ||
      watched_scopes_by_user[user_id].to_a.include?(scope)
  end

  def listeners_by_user
    @listeners_by_user ||= (
      user_ids = orphan_candidate_user_ids
      shared = SharedTask.where(user_id: user_ids).pluck(:task_id, :user_id)
      enabled = Task.active.enabled.where.not(listener: [nil, ""])
      enabled = enabled.where(user_id: user_ids).or(enabled.where(id: shared.map(&:first)))
      listeners = enabled.pluck(:id, :user_id, :listener)
      by_id = listeners.to_h { |id, _owner, listener| [id, listener] }
      grouped = listeners.group_by { |_id, owner, _listener| owner }.transform_values { |rows| rows.map(&:last) }
      shared.each { |task_id, shared_user_id|
        next unless by_id.key?(task_id)

        (grouped[shared_user_id] ||= []) << by_id[task_id]
      }
      grouped
    )
  end

  def watched_scopes_by_user
    @watched_scopes_by_user ||= (
      rows = BuddyWatch.active.where(user_id: orphan_candidate_user_ids).distinct.pluck(:user_id, :trigger_scope)
      rows.group_by(&:first).transform_values { |pairs| pairs.map(&:last) }
    )
  end

  def orphan_candidate_user_ids
    @orphan_candidate_user_ids ||= (
      scope = JilTriggerShape.where(last_seen_at: (now - ORPHAN_WINDOW)..)
      scope = scope.where(user_id: user.id) if view_scope == :mine
      scope.distinct.pluck(:user_id)
    )
  end
end
