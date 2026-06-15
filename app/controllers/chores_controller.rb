class ChoresController < ApplicationController
  before_action :authorize_user_or_guest
  before_action :ensure_chore_household!, only: [:new, :create]
  before_action :set_chore, only: [:show, :edit, :update, :destroy]
  before_action :require_chore_manager!, only: [:create, :update, :destroy]
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
  def reorder
    return render(json: { error: "forbidden" }, status: :forbidden) unless current_user.can_manage_chores?

    ids = Array(params[:ids]).map(&:to_i).reject(&:zero?)
    return render json: { ok: true } if ids.empty?

    positions = ids.each_with_index.to_h
    accessible_ids = current_user.accessible_chores.where(id: ids).pluck(:id)
    return render(json: { ok: true, count: 0 }) if accessible_ids.empty?

    # cid + position pulled from server-trusted sources (DB pluck, array
    # index) — both Integers, safe to inline. Single bulk UPDATE rather
    # than N round-trips.
    case_sql = accessible_ids.map { |cid| "WHEN #{cid.to_i} THEN #{positions[cid].to_i}" }.join(" ")
    Chore.where(id: accessible_ids).update_all(
      "sort_order = CASE id #{case_sql} END, updated_at = NOW()",
    )

    MonitorChannel.broadcast_to(current_user, {
      id:        :chores,
      channel:   :chores,
      timestamp: Time.current.to_i,
      data:      {
        reason:        :order_changed,
        actor_user_id: current_user.id,
        actor_tab_id:  params[:tab_id],
        ids:           ids,
        server_ts:     Time.current.iso8601(3),
      },
    })
    render json: { ok: true, count: accessible_ids.size }
  end

  # POST /chores/items/:id/mark_due — stamp the chore as "needs to get
  # done." Household-wide (the column lives on Chore), cleared by any
  # ChoreCompletion. Idempotent re-stamp refreshes the timestamp so a
  # second mark on a later day resets the overdue-vs-due-today gate.
  def mark_due
    chore = current_user.accessible_chores.find(params[:id])
    chore.update!(marked_due_at: Time.current)
    render json: chore_response_payload(chore)
  end

  # DELETE /chores/items/:id/mark_due — clear the stamp without
  # completing the chore.
  def unmark_due
    chore = current_user.accessible_chores.find(params[:id])
    chore.update!(marked_due_at: nil) if chore.marked_due?
    render json: chore_response_payload(chore)
  end

  # POST /chores/items/:id/dailies — pin a chore to the viewer's
  # personal Dailies section on Today. Idempotent; if already pinned,
  # the existing row is returned. New pins land at the end.
  def pin_daily
    chore = current_user.accessible_chores.find(params[:id])
    daily = ChoreDaily.find_or_initialize_by(user: current_user, chore: chore)
    if daily.new_record?
      next_order = (current_user.chore_dailies.maximum(:sort_order) || -1) + 1
      daily.sort_order = next_order
      daily.save!
    end
    broadcast_dailies_changed(reason: :pinned, chore_id: chore.id)
    render json: dailies_payload
  end

  # DELETE /chores/items/:id/dailies — unpin from Dailies.
  def unpin_daily
    daily = current_user.chore_dailies.find_by(chore_id: params[:id])
    daily&.destroy
    broadcast_dailies_changed(reason: :unpinned, chore_id: params[:id].to_i)
    render json: dailies_payload
  end

  # POST /chores/hot_picks/:chore_id/rotate — remove a single Hot Pick
  # and roll a replacement. Manager-only; the replacement's rules and
  # weighting live in ChoreDailyResetWorker so they stay in lockstep
  # with the morning batch.
  def rotate_hot_pick
    return render(json: { error: "forbidden" }, status: :forbidden) unless current_user.can_manage_chores?

    day = ChoreDay.current(current_user)
    removed = ChoreHotPick.find_by(day_key: day, chore_id: params[:chore_id])
    return render(json: { error: "not_found" }, status: :not_found) unless removed

    replacement = nil
    ChoreHotPick.transaction do
      multiplier = removed.multiplier
      removed_id = removed.chore_id
      removed.destroy!
      replacement = ChoreDailyResetWorker.new.rotate!(
        day:               day,
        excluded_chore_id: removed_id,
        multiplier:        multiplier,
      )
    end

    ChoreBroadcaster.broadcast_hot_picks_refreshed!
    render json: {
      removed_chore_id:     params[:chore_id].to_i,
      replacement_chore_id: replacement&.chore_id,
      server_ts:            Time.current.iso8601(3),
    }
  end

  # GET/PATCH /chores/notification_preferences — read or update the
  # viewer's per-event opt-out toggles. Empty hash = subscribed to
  # everything (User#wants_chore_notification?). Body shape is
  # { chore_notify_prefs: { transfer_received: bool, ... } }.
  def notification_preferences
    render json: { prefs: current_prefs }
  end

  def update_notification_preferences
    incoming = params.fetch(:chore_notify_prefs, {}).permit(*User::CHORE_NOTIFY_KINDS).to_h
    bools = incoming.transform_values { |v| ActiveModel::Type::Boolean.new.cast(v) }
    current_user.update!(chore_notify_prefs: current_prefs.merge(bools))
    render json: { prefs: current_prefs }
  end

  # PATCH /chores/dailies/order — body { ids: [3, 7, 1, ...] }
  # Bulk reorder the viewer's Dailies. Ids not owned by the viewer are
  # ignored; ids absent from the payload keep their existing position.
  def reorder_dailies
    ids = Array(params[:ids]).map(&:to_i).reject(&:zero?)
    owned_ids = current_user.chore_dailies.where(chore_id: ids).pluck(:chore_id)
    if owned_ids.any?
      positions = ids.each_with_index.to_h
      case_sql = owned_ids.map { |cid| "WHEN #{cid.to_i} THEN #{positions[cid].to_i}" }.join(" ")
      current_user.chore_dailies.where(chore_id: owned_ids).update_all(
        "sort_order = CASE chore_id #{case_sql} END, updated_at = NOW()",
      )
    end
    broadcast_dailies_changed(reason: :reordered)
    render json: dailies_payload
  end

  # Lightweight: balance + fresh CSRF token so the offline-queue can
  # recover from token rotation without a full sync.
  def csrf
    breakdown = current_user.chore_balance_breakdown
    render json: {
      token:          form_authenticity_token,
      balance:        breakdown[:balance],
      today_earnings: breakdown[:today_earnings],
    }
  end

  # GET /chores/items/:id/state
  # Returns a single canonical chore JSON. Called after a broadcast
  # lands for that chore, or to verify state after an optimistic update.
  def state
    chore = current_user.accessible_chores.unscope(where: :archived_at).find(params[:id])
    render json: {
      chore:     ChoreSerializer.new(chore, viewer: current_user).as_json,
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
      # Include completions whose record was TOUCHED since
      # since_ts (updated_at) in addition to those whose
      # completed_at landed since then. Edits that move a
      # completion BACKWARDS in time (today → yesterday on
      # History) leave completed_at < since_ts but bump
      # updated_at — without the OR they'd be invisible to
      # an offline tab catching up later.
      # Scoped to the whole household, not just current_user: a
      # household-shared chore completed by another member changes
      # this viewer's done_count_today / last_actor / today_visible,
      # but chore.updated_at isn't bumped on completion create — so
      # without the household scope the delta misses it and the page
      # stays stale until a full sync (refresh or 4am rollover).
      touched_ids = ChoreCompletion
        .where(user_id: current_user.chore_household_user_ids)
        .where("completed_at >= :ts OR updated_at >= :ts", ts: since_ts)
        .distinct.pluck(:chore_id).to_set
      # Hot-pick rotation and streak resets don't touch
      # chore.updated_at, so the basic diff above would miss
      # chores whose hot_multiplier/streak_multiplier just
      # changed. Pull their ids in explicitly.
      touched_ids.merge(ChoreHotPick.where(day_key: @day).where(created_at: since_ts..).pluck(:chore_id))
      touched_ids.merge(ChoreStreak.where(user_id: current_user.id).where(updated_at: since_ts..).pluck(:chore_id))
      @chores.select { |c| c.updated_at > since_ts || touched_ids.include?(c.id) }
    else
      @chores
    end

    render json: {
      server_ts:        Time.current.iso8601(3),
      day_key:          @day.iso8601,
      balance:          @balance_total,
      today_earnings:   @balance_today,
      # `chores` is the incremental delta when `since_ts` was supplied,
      # otherwise the full accessible set. Either way `active_chore_ids`
      # is the canonical full id list — the single source of truth the
      # client uses to drop anything stale from its cache.
      chores:           @ctx.serialize_all(chosen),
      active_chore_ids: @chores.map(&:id),
      lookahead:        @lookahead_json,
      daily_ids:        @daily_ids,
    }
  end

  # GET /chores/balance — server-rendered shell. The Recent History
  # block is hydrated client-side (via /chores/recent_history) so the
  # cached shell never serves stale balance rows.
  def balance
    @balance = current_user.chore_balance
    @goals = current_user.chore_goals.active.ordered.to_a
    household_id = current_user.chore_household_id
    @streak_bonuses = if household_id
      ChoreStreakBonus.where(chore_household_id: household_id).includes(:chore).order(:sort_order, :id)
    else
      ChoreStreakBonus.none
    end
    @household_chores = current_user.accessible_chores.order(:name).to_a
    @transfer_recipients = if household_id
      User.where(chore_household_id: household_id).where.not(id: current_user.id).order(:username).to_a
    else
      []
    end
    @can_manage_chores = current_user.can_manage_chores?
  end

  def history
    @breakdown = current_user.chore_balance_breakdown
    @balance = @breakdown[:balance]
    @page = [params[:page].to_i, 1].max
    @per = 50
    @q = params[:q].to_s
    @total_pages = 1 # filled in by load_history_window when JSON-requested

    respond_to do |format|
      format.html
      format.json {
        load_history_window
        render json: history_json_payload
      }
    end
  end

  # GET /chores/recent_history — last 10 completions/withdrawals/transfers
  # interleaved, used to hydrate the Balance page's Recent History
  # section. Kept separate from /chores/sync so the Balance shell can
  # render instantly (with a loading state) while this fetch lands.
  def recent_history
    completions = current_user.chore_completions
      .includes(:chore)
      .order(completed_at: :desc).limit(10).to_a
    withdrawals = current_user.chore_withdrawals
      .order(created_at: :desc).limit(10).to_a
    transfers = ChoreTransfer
      .where("from_user_id = :id OR to_user_id = :id", id: current_user.id)
      .includes(:from_user, :to_user)
      .order(created_at: :desc).limit(10).to_a

    entries = (completions + withdrawals + transfers).sort_by { |e| -entry_ts(e).to_f }.first(10)

    today = ChoreDay.current(current_user)
    today_earnings = current_user.chore_completions.where(day_key: today).sum(:paid_pebbles)
    render json: {
      entries:        entries.map { |e| history_entry_json(e) },
      balance:        current_user.chore_balance,
      today_earnings: today_earnings,
      server_ts:      Time.current.iso8601(3),
    }
  end

  # GET /chores/items/:id/history — chore-specific completion log used
  # by the edit-mode long-press modal. Household-cooldown chores
  # include every household member's completion; personal-cooldown
  # chores stay scoped to the viewer.
  def chore_history
    chore = current_user.accessible_chores.unscope(where: :archived_at).find(params[:id])
    scope_user_ids = if chore.share_household?
      current_user.chore_household_user_ids
    else
      [current_user.id]
    end
    completions = ChoreCompletion
      .where(chore_id: chore.id, user_id: scope_user_ids)
      .includes(:user)
      .order(completed_at: :desc)
      .limit(50)
    render json: {
      chore:   history_chore_json(chore),
      entries: completions.map { |c|
        # Anonymous completions never attribute to the recording user.
        # Send actor_username: nil so the JS renders the "Anonymous"
        # pill instead of the recorder's name.
        {
          id:                c.id,
          user_id:           c.user_id,
          actor_username:    c.anonymous ? nil : c.user&.username,
          anonymous:         c.anonymous,
          paid_pebbles:      c.paid_pebbles,
          base_pebbles:      c.base_pebbles,
          hot_multiplier:    c.hot_multiplier.to_f,
          streak_multiplier: c.streak_multiplier.to_f,
          note:              c.note.to_s,
          payout_skipped:    c.payout_skipped,
          completed_at:      c.completed_at.iso8601(3),
          when_label:        c.completed_at.strftime("%b %-d, %l:%M%P").squeeze(" "),
        }
      },
    }
  end

  def new
    @chore = current_user.chore_household.chores.new(
      created_by_user: current_user,
      one_off:         ActiveModel::Type::Boolean.new.cast(params[:one_off]),
    )
  end

  def edit; end

  def create
    @chore = current_user.chore_household.chores.new(
      chore_params.merge(created_by_user: current_user),
    )
    if @chore.save
      ChoreNotifier.chore_assigned!(@chore, actor: current_user)
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
    previous_assignee_id = @chore.assigned_to_user_id
    if @chore.update(chore_params)
      if @chore.assigned_to_user_id != previous_assignee_id
        ChoreNotifier.chore_assigned!(@chore, actor: current_user)
      end
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
    @chores = current_user.accessible_chores
      .order(Arel.sql("sort_order ASC NULLS LAST, id ASC"))
      .to_a
    @ctx = ChoreSerializerContext.for_user(current_user, day: @day)
    @chores_json = @ctx.serialize_all(@chores)
    @daily_ids = ChoreDaily.for_user(current_user).pluck(:chore_id)
    @lookahead_json = build_lookahead_json
    @cutoff_hour = ChoreDay::CUTOFF_HOURS
    @can_manage_chores = current_user.can_manage_chores?

    breakdown = current_user.chore_balance_breakdown(@day)
    @balance_total = breakdown[:balance]
    @balance_today = breakdown[:today_earnings]
    @balance = @balance_today
  end

  # Focused "Upcoming" list — for each chore, only the EARLIEST future
  # day in the 7-day window. Items already on Today are excluded.
  # Format: { "2026-05-30" => [chore_id, ...], ... }
  #
  # Every day in the window is emitted, even when no chore matches —
  # otherwise users read the next non-empty day as "tomorrow" and
  # plan around the wrong date. The client renders an explicit
  # "Nothing scheduled" row per empty day.
  def build_lookahead_json
    today_ids = @chores_json.select { |c| c[:today_visible] }.to_set { |c| c[:id] }
    seen = Set.new
    upcoming = {}
    ((@day + 1)..(@day + 7)).each { |d| upcoming[d.iso8601] = [] }

    # First pass: any chore (one-off, sub-chore, OR recurring) with a
    # future `marked_due_at` falls into the lookahead on its marked
    # day — mirrors today_visible's gating, which honours marked_due
    # over the recurrence schedule. Without this, a sub-chore created
    # with a future due date never surfaces anywhere.
    @chores.each do |c|
      next if c.archived? || today_ids.include?(c.id) || seen.include?(c.id)
      next if c.marked_due_at.nil?

      due_day = ChoreDay.current(current_user, at: c.marked_due_at)
      next unless upcoming.key?(due_day.iso8601)

      upcoming[due_day.iso8601] << c.id
      seen << c.id
    end

    # Second pass: recurring chores follow their schedule. One-offs
    # without a marked due date have no future surfacing rule —
    # they're either visible on Today already or sitting in Grid.
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
    # Mutations can shift a chore in/out of the Upcoming window — most
    # commonly a marked_due_at change (sub-chore due date, snooze, etc).
    # Rebuilding here mirrors what /chores/sync emits so the client's
    # reconcile() path picks up the new lookahead the same way without
    # needing a follow-up sync round-trip.
    load_chore_page_data
    {
      chore:          ChoreSerializer.new(chore, viewer: current_user, ctx: @ctx).as_json,
      lookahead:      @lookahead_json,
      server_ts:      Time.current.iso8601(3),
      balance:        @balance_total,
      today_earnings: @balance_today,
    }
  end

  def dailies_payload
    {
      daily_ids: current_user.chore_dailies.order(:sort_order, :id).pluck(:chore_id),
      server_ts: Time.current.iso8601(3),
    }
  end

  # Dailies are personal — only the viewer's other tabs care. Reuses the
  # MonitorChannel "chores" envelope so the existing client subscriber
  # can fan out to its dailies handler off the same connection.
  def broadcast_dailies_changed(reason:, chore_id: nil)
    MonitorChannel.broadcast_to(current_user, {
      id:        :chores,
      channel:   :chores,
      timestamp: Time.current.to_i,
      data:      {
        reason:         :dailies_changed,
        dailies_reason: reason,
        chore_id:       chore_id,
        actor_user_id:  current_user.id,
        actor_tab_id:   params[:tab_id],
        daily_ids:      current_user.chore_dailies.order(:sort_order, :id).pluck(:chore_id),
        server_ts:      Time.current.iso8601(3),
      },
    })
  end

  def parse_iso(value)
    return nil if value.blank?

    Time.iso8601(value.to_s)
  rescue ArgumentError
    nil
  end

  # Lazily create a solo household so first-time users land in a valid
  # state when they hit New Chore. The household's after_create stamps
  # the owner membership which sync-writes users.chore_household_id.
  def ensure_chore_household!
    if ChoreHouseholdMembership.exists?(user_id: current_user.id)
      current_user.reload if current_user.chore_household_id.nil?
      return
    end

    ChoreHousehold.create!(
      owner_user: current_user,
      name:       "#{current_user.display_name}'s Household",
    )
    current_user.reload
  end

  def require_chore_manager!
    return if current_user.can_manage_chores?

    respond_to do |format|
      format.html { redirect_to chores_path, alert: "Only household managers can do that." }
      format.json { render json: { error: "Only household managers can do that." }, status: :forbidden }
    end
  end

  # Run the same paginated query the HTML view used to do. Sets
  # @entries / @total_count / @total_pages / @completion_count /
  # @withdrawal_count / @transfer_count so the JSON renderer can
  # emit consistent counts.
  def load_history_window
    page = @page
    per = @per

    # Only JOIN chores when the search needs to filter on chore fields.
    # The eager `.includes(:chore)` already loads chore via a separate
    # IN-query, so for the blank-search common case we skip the extra
    # JOIN entirely — including in the COUNT below.
    base_completions = current_user.chore_completions.includes(:chore)
    base_completions = base_completions.joins(:chore) if @q.present?
    base_withdrawals = current_user.chore_withdrawals
    base_transfers   = ChoreTransfer
      .where("from_user_id = :id OR to_user_id = :id", id: current_user.id)
      .includes(:from_user, :to_user)

    if @q.present?
      base_completions = safe_query(base_completions, @q)
      base_withdrawals = safe_query(base_withdrawals, @q)
      base_transfers   = safe_query(base_transfers,   @q)
    end

    @completion_count = base_completions.except(:includes, :order).count
    @withdrawal_count = base_withdrawals.except(:order).count
    @transfer_count   = base_transfers.except(:includes, :order).count
    @total_count = @completion_count + @withdrawal_count + @transfer_count
    @total_pages = [(@total_count.to_f / per).ceil, 1].max

    window = page * per
    completions = base_completions.order(completed_at: :desc).limit(window).to_a
    withdrawals = base_withdrawals.order(created_at: :desc).limit(window).to_a
    transfers   = base_transfers.order(created_at: :desc).limit(window).to_a

    entries = (completions + withdrawals + transfers).sort_by { |e| -entry_ts(e).to_f }
    @entries = entries[((page - 1) * per), per] || []
  end

  def history_json_payload
    page_completions = @entries.count { |e| e.is_a?(ChoreCompletion) }
    page_withdrawals = @entries.count { |e| e.is_a?(ChoreWithdrawal) }
    page_transfers   = @entries.count { |e| e.is_a?(ChoreTransfer) }
    from = ((@page - 1) * @per) + 1
    to   = [@page * @per, @total_count].min
    # Reuse the breakdown's already-computed today_earnings instead of
    # firing a second SUM query for the same window.
    today_earnings = @breakdown[:today_earnings]

    {
      page:             @page,
      per:              @per,
      total_pages:      @total_pages,
      total_count:      @total_count,
      completion_count: @completion_count,
      withdrawal_count: @withdrawal_count,
      transfer_count:   @transfer_count,
      page_completions: page_completions,
      page_withdrawals: page_withdrawals,
      page_transfers:   page_transfers,
      from:             @total_count.zero? ? 0 : from,
      to:               to,
      balance:          @balance,
      today_earnings:   today_earnings,
      entries:          @entries.map { |e| history_entry_json(e) },
      server_ts:        Time.current.iso8601(3),
    }
  end

  def entry_ts(entry)
    entry.is_a?(ChoreCompletion) ? entry.completed_at : entry.created_at
  end

  def history_entry_json(entry)
    case entry
    when ChoreCompletion
      {
        kind:              :completion,
        id:                entry.id,
        chore:             history_chore_json(entry.chore),
        paid_pebbles:      entry.paid_pebbles,
        base_pebbles:      entry.base_pebbles,
        hot_pick:          !!entry.metadata["hot_pick"],
        hot_multiplier:    entry.hot_multiplier.to_f,
        streak_multiplier: entry.streak_multiplier.to_f,
        note:              entry.note.to_s,
        completed_at:      entry.completed_at.iso8601(3),
        when_label:        entry.completed_at.strftime("%b %-d, %l:%M%P").squeeze(" "),
        payout_skipped:    entry.payout_skipped,
        skipped_reason:    entry.skipped_reason,
        anonymous:         entry.anonymous,
      }
    when ChoreWithdrawal
      {
        kind:           :withdrawal,
        id:             entry.id,
        amount_pebbles: entry.amount_pebbles,
        note:           entry.note.to_s,
        created_at:     entry.created_at.iso8601(3),
        when_label:     entry.created_at.strftime("%b %-d, %l:%M%P").squeeze(" "),
      }
    when ChoreTransfer
      direction = entry.from_user_id == current_user.id ? :outgoing : :incoming
      counterparty = direction == :outgoing ? entry.to_user : entry.from_user
      {
        kind:                  :transfer,
        id:                    entry.id,
        direction:             direction,
        amount_pebbles:        entry.amount_pebbles,
        counterparty_username: counterparty&.username,
        note:                  entry.note.to_s,
        created_at:            entry.created_at.iso8601(3),
        when_label:            entry.created_at.strftime("%b %-d, %l:%M%P").squeeze(" "),
      }
    end
  end

  def history_chore_json(chore)
    {
      id:         chore.id,
      name:       chore.name,
      short_name: chore.display_short_name,
      icon:       chore.icon.to_s,
      icon_kind:  ChoreSerializer.new(chore, viewer: current_user).send(:icon_kind),
      one_off:    chore.one_off,
    }
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

    @assignable_users = if current_user.chore_household_id
      User.where(chore_household_id: current_user.chore_household_id).order(:username).to_a
    else
      [current_user]
    end
  end

  def set_chore
    @chore = current_user.accessible_chores.unscope(where: :archived_at).find(params[:id])
  end

  def current_prefs
    User::CHORE_NOTIFY_KINDS.index_with { |kind| current_user.wants_chore_notification?(kind) }
  end

  def chore_params
    permitted = params.require(:chore).permit(
      :name, :short_name, :icon, :reward_pebbles, :target_count, :threshold_seconds,
      :one_off, :starts_on, :show_on_daily_view, :hot_eligibility,
      :sharing_mode, :assigned_to_user_id, :notes_template, :notes,
      :marked_due_at, :parent_chore_id,
      aliases:    [],
      recurrence: {}
    )

    if (csv = params.dig(:chore, :aliases_csv))
      permitted[:aliases] = csv.to_s.split(",").map(&:strip).compact_blank
    end

    # Sub-chores must be one-offs (the model enforces it). When the user
    # picks a Parent Chore in the Advanced section without flipping the
    # One-off select, coerce here so the save succeeds. Empty/blank
    # parent_chore_id means "not a sub-chore" — leave one_off alone.
    if permitted.key?(:parent_chore_id)
      raw_parent = permitted[:parent_chore_id].to_s.strip
      permitted[:parent_chore_id] = raw_parent.presence
      permitted[:one_off] = true if permitted[:parent_chore_id].present?
    end

    if (hours = params.dig(:chore, :threshold_hours)).present?
      permitted[:threshold_seconds] = hours.to_i * 3600
    end

    # `marked_due_at` arrives from the form as a YYYY-MM-DD date string.
    # Anchor to the 4am chore-day start in the viewer's zone so the
    # serializer's day-range comparisons line up with the rest of the
    # chore system. Blank clears the stamp.
    if permitted.key?(:marked_due_at)
      raw = permitted[:marked_due_at].to_s.strip
      permitted[:marked_due_at] = if raw.blank?
        nil
      else
        date = (Date.parse(raw) rescue nil)
        date ? ChoreDay.starts_at(date, current_user) : nil
      end
    end

    permitted
  end
end
