class ChoresController < ApplicationController
  before_action :authorize_user_or_guest
  before_action :set_chore, only: [:show, :edit, :update, :destroy]
  before_action :assignable_users, only: [:index, :today, :balance, :history, :new]
  helper_method :assignable_users

  # ============================================================
  # Unified Grid/Today page — renders the SAME template at both
  # /chores and /chores/today, differing only in `data-active-view`.
  # The page paints from inline bootstrap JSON; JS templates own all
  # card rendering. No server-side HTML partials for chores anywhere.
  # ============================================================

  def index
    @active_view = :grid
    load_chore_page_data
    render :page
  end

  def today
    @active_view = :today
    load_chore_page_data
    render :page
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

  # Lightweight: balance + fresh CSRF token so the offline-queue can
  # recover from token rotation without a full sync.
  def csrf
    breakdown = current_user.chore_balance_breakdown
    render json: {
      token: form_authenticity_token,
      balance: breakdown[:balance],
      today_earnings: breakdown[:today_earnings],
    }
  end

  # GET /chores/items/:id/state
  # Returns a single canonical chore JSON. Called after a broadcast
  # lands for that chore, or to verify state after an optimistic update.
  def state
    chore = current_user.accessible_chores.unscope(where: :archived_at).find(params[:id])
    render json: {
      chore: ChoreSerializer.new(chore, viewer: current_user).as_json,
      server_ts: Time.current.iso8601(3),
    }
  end

  # GET /chores/sync?since=<iso8601>
  # Cold-boot + reconnect diff. When `since` is provided, returns only
  # the chores updated OR touched-by-a-completion since that timestamp;
  # otherwise the full accessible set.
  def sync
    load_chore_page_data
    since_ts = parse_iso(params[:since])

    # Cross-day sync: the incremental delta below only returns chores
    # the user TOUCHED since `since_ts`. After the 4am ChoreDay
    # boundary that's not enough — hot picks rotate, today's
    # done_count_today resets to 0 for everything, today_visible
    # flips for cooldown/scheduled chores, lookahead shifts a day.
    # When the supplied timestamp lives in a prior chore-day, ignore
    # it so the full set comes through. Cheap (one Date compare) and
    # the chore-day boundary only crosses once per day.
    if since_ts && ChoreDay.current(current_user, at: since_ts) != @day
      since_ts = nil
    end

    chosen = if since_ts
               touched_ids = ChoreCompletion
                 .where(user_id: current_user.id, completed_at: since_ts..)
                 .distinct.pluck(:chore_id).to_set
               @chores.select { |c| c.updated_at > since_ts || touched_ids.include?(c.id) }
             else
               @chores
             end

    render json: {
      server_ts: Time.current.iso8601(3),
      day_key: @day.iso8601,
      balance: @balance_total,
      today_earnings: @balance_today,
      chores: @ctx.serialize_all(chosen),
      lookahead: @lookahead_json,
      archived_chore_ids: sync_archived_ids(since_ts),
    }
  end

  # GET /chores/balance — server-rendered (still mostly informational).
  def balance
    @balance = current_user.chore_balance
    @goals = current_user.chore_goals.active.ordered.to_a
    @recent_completions = current_user.chore_completions
      .includes(:chore)
      .order(completed_at: :desc).limit(10)
    @withdrawals = current_user.chore_withdrawals.order(created_at: :desc).limit(10)
    @achievements = ChoreAchievement.active.to_a
    @earned_ids = current_user.user_chore_achievements.pluck(:chore_achievement_id).to_set
    @multipliers = current_user.chore_multipliers.order(:sort_order, :id)
  end

  def history
    @balance = current_user.chore_balance
    @page = [params[:page].to_i, 1].max
    @per = 50
    @q = params[:q].to_s
    page = @page
    per = @per

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
        format.json { render json: chore_response_payload(@chore), status: :created }
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
        format.json { render json: chore_response_payload(@chore) }
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
      format.json { render json: { archived_chore_id: @chore.id, server_ts: Time.current.iso8601(3) } }
    end
  end

  private

  # Bootstrap the unified page: load enough to inline the chore set as
  # JSON in the page so JS templates can paint immediately, without a
  # round-trip and without server-side card rendering.
  def load_chore_page_data
    @day = ChoreDay.current(current_user)
    @chores = ordered_for_current_user(current_user.accessible_chores).to_a
    @ctx = ChoreSerializerContext.for_user(current_user, day: @day)
    @chores_json = @ctx.serialize_all(@chores)
    @lookahead_json = build_lookahead_json
    @cutoff_hour = ChoreDay::CUTOFF_HOURS

    breakdown = current_user.chore_balance_breakdown(@day)
    @balance_total = breakdown[:balance]
    @balance_today = breakdown[:today_earnings]
    @balance = @balance_today
  end

  # Focused "Upcoming" list — for each chore, only the EARLIEST future
  # day in the 7-day window. Items already on Today are excluded.
  # Format: { "2026-05-30" => [chore_id, ...], ... } so the client can
  # render the strip directly from the store without re-implementing
  # the recurrence-matching logic.
  def build_lookahead_json
    today_ids = @chores_json.select { |c| c[:today_visible] }.map { |c| c[:id] }.to_set
    seen = Set.new
    upcoming = Hash.new { |h, k| h[k] = [] }
    candidates = @chores.reject { |c| c.one_off || c.show_on_daily_view.to_sym == :never }
    ((@day + 1)..(@day + 7)).each do |d|
      candidates.each do |c|
        next unless c.scheduled?
        next if today_ids.include?(c.id) || seen.include?(c.id)

        last_day = @ctx.last_completion_by_chore[c.id]&.day_key
        next unless c.matches_day?(d, current_user, last_completed_day: last_day)

        upcoming[d.iso8601] << c.id
        seen << c.id
      end
    end
    upcoming
  end

  def chore_response_payload(chore)
    {
      chore: ChoreSerializer.new(chore, viewer: current_user).as_json,
      server_ts: Time.current.iso8601(3),
      balance: current_user.chore_balance,
      today_earnings: current_user.chore_balance_breakdown(ChoreDay.current(current_user))[:today_earnings],
    }
  end

  def sync_archived_ids(since_ts)
    scope = current_user.accessible_chores.unscope(where: :archived_at).where.not(archived_at: nil)
    scope = scope.where(archived_at: since_ts..) if since_ts
    scope.pluck(:id)
  end

  def parse_iso(value)
    return nil if value.blank?

    Time.iso8601(value.to_s)
  rescue ArgumentError
    nil
  end

  def ordered_for_current_user(scope)
    join_sql = ActiveRecord::Base.sanitize_sql_array([
      "LEFT JOIN chore_user_orders ON chore_user_orders.chore_id = chores.id AND chore_user_orders.user_id = ?",
      current_user.id,
    ])
    scope.joins(join_sql).order(Arel.sql("chore_user_orders.sort_order ASC NULLS LAST, chores.id ASC"))
  end

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

  def assignable_users
    return @assignable_users if defined?(@assignable_users)

    @assignable_users = User.where(id: current_user.chore_owner_user_ids).order(:username).to_a
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

    if (csv = params.dig(:chore, :aliases_csv))
      permitted[:aliases] = csv.to_s.split(",").map(&:strip).reject(&:blank?)
    end

    if (hours = params.dig(:chore, :threshold_hours)).present?
      permitted[:threshold_seconds] = hours.to_i * 3600
    end

    permitted
  end
end
