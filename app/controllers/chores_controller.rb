class ChoresController < ApplicationController
  before_action :authorize_user_or_guest
  before_action :set_chore, only: [:show, :edit, :update, :destroy]
  before_action :assignable_users, only: [:index, :today, :balance, :history, :new]
  helper_method :assignable_users

  def index
    @chores = ordered_for_current_user(current_user.accessible_chores).to_a
    @day = ChoreDay.current(current_user)
    @now = Time.current
    @hot_picks = ChoreHotPick.lookup_for(@day)
    @completions_today = ChoreCompletion
      .where(user_id: current_user.id, day_key: @day)
      .group(:chore_id).count
    @last_completions = ChoreCompletion
      .where(user_id: current_user.id, chore_id: @chores.map(&:id))
      .select("DISTINCT ON (chore_id) chore_id, completed_at, payout_skipped, paid_pebbles, day_key")
      .order(:chore_id, completed_at: :desc)
      .index_by(&:chore_id)
    @balance = current_user.chore_balance
  end

  # PATCH /chores/order — body { ids: [3, 7, 1, ...] }
  # Upsert sort_order per (current_user, chore_id) in a single bulk query.
  def reorder
    ids = Array(params[:ids]).map(&:to_i).reject(&:zero?)
    return render json: { ok: true } if ids.empty?

    accessible_ids = current_user.accessible_chores.where(id: ids).pluck(:id).to_set
    rows = ids.each_with_index.filter_map { |chore_id, idx|
      next unless accessible_ids.include?(chore_id)

      { user_id: current_user.id, chore_id: chore_id, sort_order: idx,
        created_at: Time.current, updated_at: Time.current }
    }
    ChoreUserOrder.upsert_all(rows, unique_by: :index_chore_user_orders_pair) if rows.any?
    # Broadcast to every device of the SAME user (sortation is per-user;
    # other share-group members aren't affected). Receivers re-apply the
    # order without reloading.
    MonitorChannel.broadcast_to(current_user, {
      id: :chores,
      channel: :chores,
      timestamp: Time.current.to_i,
      data: {
        reason: :order_changed,
        actor_user_id: current_user.id,
        actor_tab_id: params[:tab_id],
        ids: ids,
        server_ts: Time.current.iso8601(3),
      },
    })
    render json: { ok: true, count: rows.size }
  end

  def today
    @day = ChoreDay.current(current_user)
    @now = Time.current
    breakdown = current_user.chore_balance_breakdown(@day)
    @balance = breakdown[:today_earnings] # Today header shows today's earnings
    @total_balance = breakdown[:balance]
    @hot_picks = ChoreHotPick.lookup_for(@day)

    # Stable order — sort_order, then id. The Today layout is frozen
    # within a day, so items must never re-arrange on re-renders.
    chores = ordered_for_current_user(
      current_user.accessible_chores.where.not(show_on_daily_view: Chore.show_on_daily_views[:never])
    ).to_a
    chore_ids = chores.map(&:id)

    # Per the sharing-mode spec: personal/assigned tasks show this user's
    # data only; household tasks roll up ALL share-group members so
    # everyone sees the same completion state.
    household_ids = chores.select(&:share_household?).map(&:id)
    personal_ids  = chore_ids - household_ids
    share_group_ids = household_ids.empty? ? [] : household_user_ids_for_share_group

    @last_completion_by_chore = bulk_last_completion(personal_ids, [current_user.id])
      .merge(bulk_last_completion(household_ids, share_group_ids))

    @completion_actor_by_chore = bulk_last_actor(household_ids, share_group_ids)

    @completions_today = ChoreCompletion
      .where(day_key: @day, chore_id: personal_ids, user_id: current_user.id)
      .group(:chore_id).count
      .merge(
        ChoreCompletion
          .where(day_key: @day, chore_id: household_ids, user_id: share_group_ids)
          .group(:chore_id).count
      )

    # ONE query for all completion-days in the carryover window across
    # all visible chores — kills the N+1 EXISTS check that fired once
    # per chore inside scheduled_today_or_carried_over?.
    @completion_days_by_chore = ChoreCompletion
      .where(user_id: current_user.id, chore_id: chore_ids, day_key: (@day - 14)..@day)
      .distinct.pluck(:chore_id, :day_key)
      .group_by(&:first)
      .transform_values { |entries| entries.map(&:last).to_set }

    @scheduled_today = chores.select { |c| visible_on_daily?(c, @day) || c.one_off }
    @lookahead = lookahead(chores.reject(&:one_off), @day)
  end

  # Lightweight endpoint for the offline queue flusher to pick up a
  # fresh CSRF token when the cached HTML's <meta> went stale.
  def csrf
    breakdown = current_user.chore_balance_breakdown
    render json: {
      token: form_authenticity_token,
      balance: breakdown[:balance],
      today_earnings: breakdown[:today_earnings],
    }
  end

  # Per-chore live state — fetched after a broadcast or visibility
  # change so the page can update ONE card without reloading the DOM.
  # Returns the same shape the completion endpoints emit. `server_ts` is
  # the high-resolution server timestamp the client uses to detect stale
  # responses vs. a local optimistic click.
  def state
    chore = current_user.accessible_chores.unscope(where: :archived_at).find(params[:id])
    day = ChoreDay.current(current_user)
    user_ids = chore.share_household? ? household_user_ids_for_share_group : [current_user.id]

    last = ChoreCompletion
      .where(chore_id: chore.id, user_id: user_ids)
      .order(completed_at: :desc).first
    actor = (chore.share_household? && last && last.user_id != current_user.id) ?
      User.where(id: last.user_id).pluck(:username).first : nil
    completions_today = ChoreCompletion
      .where(chore_id: chore.id, user_id: user_ids, day_key: day).count
    today_earnings = current_user.chore_completions.where(day_key: day).sum(:paid_pebbles)

    # `view` lets the JS ask for the right card partial to splice in
    # (Today renders a circle, everywhere else renders a grid card).
    # If the requester didn't specify, we default to grid so the JSON is
    # still useful for non-card consumers.
    last_completion_for_card = (last && last.user_id == current_user.id) ? last : nil
    actor_label = (chore.share_household? && actor && last && last.user_id != current_user.id) ? actor : nil
    card_html = rendered_card_html(
      chore,
      params[:view],
      done_count: completions_today,
      last_completion: last_completion_for_card,
      actor_label: actor_label,
    )

    render json: {
      chore_id: chore.id,
      balance: current_user.chore_balance,
      today_earnings: today_earnings,
      completions_today: completions_today,
      last_completed_at: last&.completed_at&.iso8601(3),
      actor_username: actor,
      archived: chore.archived?,
      html: card_html,
      server_ts: Time.current.iso8601(3),
    }
  end

  def history
    @balance = current_user.chore_balance
    @page = [params[:page].to_i, 1].max
    @per = 50
    @q = params[:q].to_s
    page = @page
    per = @per

    # Each source-scope is filtered + counted independently using the
    # app-wide .query(q) breaker. Chore-name filtering needs the chores
    # table joined so `chores.name ILIKE %x%` resolves.
    base_completions = current_user.chore_completions.includes(:chore).joins(:chore)
    base_withdrawals = current_user.chore_withdrawals

    if @q.present?
      base_completions = safe_query(base_completions, @q)
      base_withdrawals = safe_query(base_withdrawals, @q)
    end

    @completion_count = base_completions.except(:includes, :order).count
    @withdrawal_count = base_withdrawals.except(:order).count
    @total_count = @completion_count + @withdrawal_count
    @total_pages = [(@total_count.to_f / per).ceil, 1].max

    # Pull a window per source — enough to fill the requested page. We
    # then merge + slice in memory; this stays O(per) work.
    window = page * per
    completions = base_completions.order(completed_at: :desc).limit(window).to_a
    withdrawals = base_withdrawals.order(created_at: :desc).limit(window).to_a

    entries = (completions + withdrawals).sort_by { |e|
      ts = e.is_a?(ChoreCompletion) ? e.completed_at : e.created_at
      -ts.to_f
    }
    @entries = entries[((page - 1) * per), per] || []
    @has_next = @page < @total_pages
  end

  def balance
    @balance = current_user.chore_balance
    @goals = current_user.chore_goals.active.ordered.to_a
    # Balance page shows just the 10 most recent transactions (mixed).
    # Pull 10 of each, the view merges and slices to 10 again.
    @recent_completions = current_user.chore_completions
      .includes(:chore)
      .order(completed_at: :desc).limit(10)
    @withdrawals = current_user.chore_withdrawals.order(created_at: :desc).limit(10)
    @achievements = ChoreAchievement.active.to_a
    @earned_ids = current_user.user_chore_achievements.pluck(:chore_achievement_id).to_set
    @multipliers = current_user.chore_multipliers.order(:sort_order, :id)
  end

  def new
    @chore = current_user.chores.new(one_off: ActiveModel::Type::Boolean.new.cast(params[:one_off]))
  end

  def edit; end

  def create
    @chore = current_user.chores.new(chore_params)
    if @chore.save
      ChoreBroadcaster.broadcast_changes!(current_user, @chore)
      respond_to do |format|
        format.html { redirect_to action: (@chore.one_off ? :today : :index) }
        format.json { render json: serialize(@chore).merge(html: rendered_card_html(@chore, params[:view])), status: :created }
      end
    else
      respond_to do |format|
        format.html { render :new, status: :unprocessable_entity }
        format.json { render json: { errors: @chore.errors.full_messages }, status: :unprocessable_entity }
      end
    end
  end

  def update
    if @chore.update(chore_params)
      ChoreBroadcaster.broadcast_changes!(current_user, @chore)
      respond_to do |format|
        format.html { redirect_to chores_path }
        format.json { render json: serialize(@chore).merge(html: rendered_card_html(@chore, params[:view])) }
      end
    else
      respond_to do |format|
        format.html { render :edit, status: :unprocessable_entity }
        format.json { render json: { errors: @chore.errors.full_messages }, status: :unprocessable_entity }
      end
    end
  end

  def destroy
    @chore.update!(archived_at: Time.current)
    ChoreBroadcaster.broadcast_changes!(current_user, @chore)
    respond_to do |format|
      format.html { redirect_to chores_path }
      format.json { head :no_content }
    end
  end

  private

  # Apply the current user's saved chore ordering as a single SQL JOIN.
  # Items without an explicit order row sort to the end (NULLS LAST),
  # with chore.id as a deterministic tiebreaker so the tail never
  # shuffles. Index `index_chore_user_orders_pair` covers the join.
  def ordered_for_current_user(scope)
    join_sql = ActiveRecord::Base.sanitize_sql_array([
      "LEFT JOIN chore_user_orders ON chore_user_orders.chore_id = chores.id AND chore_user_orders.user_id = ?",
      current_user.id,
    ])
    scope.joins(join_sql).order(Arel.sql("chore_user_orders.sort_order ASC NULLS LAST, chores.id ASC"))
  end

  # The app-wide `.query` scope uses `unscoped`, which would drop my
  # user / joins constraints. Generate the WHERE-fragment from the
  # search-breaker tree and apply it to the live scope directly so all
  # current filtering (user, joins(:chore)) survives.
  def safe_query(scope, q)
    return scope if q.blank?

    breaker = ::Tokenizing::Node.parse(q)
    fragment = scope.klass.unscoped.query_by_node(breaker).stripped_sql
    return scope if fragment.blank?

    scope.where(fragment)
  rescue StandardError => e
    Rails.logger.warn("Chores history query failed: #{e.message}")
    scope
  end

  # Every user in the current user's household — themselves + everyone
  # on the other side of any ChoreShare row (symmetric). Returns User
  # records ordered by username for the <select>.
  def assignable_users
    return @assignable_users if defined?(@assignable_users)

    @assignable_users = User.where(id: current_user.chore_owner_user_ids).order(:username).to_a
  end

  def household_user_ids_for_share_group
    @household_user_ids ||= current_user.chore_owner_user_ids
  end

  def bulk_last_completion(chore_ids, user_ids)
    return {} if chore_ids.empty? || user_ids.empty?

    ChoreCompletion
      .where(user_id: user_ids, chore_id: chore_ids)
      .select("DISTINCT ON (chore_id) chore_id, user_id, completed_at, payout_skipped, day_key")
      .order(:chore_id, completed_at: :desc)
      .index_by(&:chore_id)
  end

  def bulk_last_actor(chore_ids, user_ids)
    return {} if chore_ids.empty? || user_ids.empty?

    rows = ChoreCompletion
      .where(user_id: user_ids, chore_id: chore_ids)
      .select("DISTINCT ON (chore_id) chore_id, user_id")
      .order(:chore_id, completed_at: :desc)
    actor_user_ids = rows.map(&:user_id).uniq
    actors = User.where(id: actor_user_ids).index_by(&:id)
    rows.each_with_object({}) { |r, h| h[r.chore_id] = actors[r.user_id] }
  end

  # FROZEN LAYOUT (per spec): anything that earned its way onto the
  # Today view today STAYS until the next daily reset. Concretely: any
  # chore with a completion today is visible regardless of schedule,
  # cooldown, or daily_view enum.
  #
  # Otherwise the enum picks the rule:
  #   :always                       — show always
  #   :when_scheduled               — scheduled today or carried over
  #   :when_available               — cooldown elapsed
  #   :when_scheduled_and_available — both
  #   :never                        — never (filtered upstream)
  def visible_on_daily?(chore, day)
    return true if chore.daily_always?
    return true if @completions_today.fetch(chore.id, 0).positive?

    last_completion = @last_completion_by_chore[chore.id]
    last_day = last_completion&.day_key
    scheduled = scheduled_today_or_carried_over?(chore, day, last_day)
    available = chore.cooldown_elapsed?(current_user, last_completion: last_completion, now: @now)

    # `when_scheduled_and_available` carries the "Scheduled or Available"
    # label in the form — semantic is OR (either condition triggers
    # visibility). Enum INTEGER value kept for backwards compat.
    case chore.show_on_daily_view.to_sym
    when :when_scheduled               then scheduled
    when :when_available               then available
    when :when_scheduled_and_available then scheduled || available
    else false
    end
  end

  def scheduled_today_or_carried_over?(chore, day, last_completed_day)
    return false unless chore.scheduled?
    return true if chore.matches_day?(day, current_user, last_completed_day: last_completed_day)

    # Relative recurrences self-carry — already matched if due.
    return false if chore.relative?

    last_scheduled_day = (day - 14..day - 1).reverse_each.find { |d|
      chore.matches_day?(d, current_user, last_completed_day: last_completed_day)
    }
    return false if last_scheduled_day.blank?

    # Carryover check in-memory against the bulk-preloaded set of
    # completion day_keys, instead of running an EXISTS query per chore.
    completed_days = @completion_days_by_chore.fetch(chore.id, Set.new)
    !completed_days.any? { |d| d >= last_scheduled_day && d <= day }
  end

  def lookahead(chores, day, days: 7)
    upcoming = Hash.new { |h, k| h[k] = [] }
    chores.each do |c|
      next unless c.scheduled?

      last_day = @last_completion_by_chore[c.id]&.day_key
      ((day + 1)..(day + days)).each do |d|
        upcoming[d] << c if c.matches_day?(d, current_user, last_completed_day: last_day)
      end
    end
    upcoming
  end

  def set_chore
    @chore = current_user.accessible_chores.unscope(where: :archived_at).find(params[:id])
  end

  def chore_params
    permitted = params.require(:chore).permit(
      :name, :short_name, :icon, :reward_pebbles, :threshold_seconds,
      :one_off, :starts_on, :show_on_daily_view,
      :sharing_mode, :assigned_to_user_id,
      aliases: [],
      recurrence: {},
    )

    # Form may post aliases as CSV string instead of array; normalise.
    if (csv = params.dig(:chore, :aliases_csv))
      permitted[:aliases] = csv.to_s.split(",").map(&:strip).reject(&:blank?)
    end

    # Threshold hours → seconds for the form-fallback path.
    if (hours = params.dig(:chore, :threshold_hours)).present?
      permitted[:threshold_seconds] = hours.to_i * 3600
    end

    permitted
  end

  # Render the right card partial for the page the user is currently on
  # (the JS submits the active mode as `view` so the server doesn't have
  # to guess). Today gets the circle; everywhere else gets the grid card.
  # Optional locals let `state` pass through real done_count / last
  # completion / actor; create+update default them to fresh-state.
  def rendered_card_html(chore, view, done_count: 0, last_completion: nil, actor_label: nil, hot: nil)
    partial = view.to_s == "today" ? "circle_card" : "grid_card"
    locals = { chore: chore, done_count: done_count, last_completion: last_completion, hot: hot }
    locals[:actor_label] = actor_label if partial == "circle_card"
    render_to_string(partial: partial, locals: locals, formats: [:html])
  end

  def serialize(chore)
    {
      id: chore.id,
      name: chore.name,
      short_name: chore.short_name,
      icon: chore.icon,
      reward_pebbles: chore.reward_pebbles,
      threshold_seconds: chore.threshold_seconds,
      aliases: chore.aliases_array,
      one_off: chore.one_off,
      sort_order: chore.sort_order,
      recurrence: chore.recurrence,
      starts_on: chore.starts_on,
    }
  end
end
