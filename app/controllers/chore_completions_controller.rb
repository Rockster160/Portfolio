class ChoreCompletionsController < ApplicationController
  before_action :authorize_user_or_guest
  before_action :require_chore_manager!, only: [:update]

  # POST /chores/items/:chore_id/anonymous_completion
  # Records a completion for scheduling/cooldown purposes that credits
  # no household member. user_id captures the recorder; everything
  # display-side ignores anonymous rows (see ChoreCompletion#credited).
  def anonymous_completion
    tapped = current_user.accessible_chores.find(params[:chore_id])
    # Sub-chore taps credit the parent the same way ChoreCompleter does
    # — anonymous or not, the chore_id column always points at the
    # creditable row. Without this, the parent's schedule + cooldown
    # would silently ignore an anonymous tap of a sub-chore.
    credit = tapped.parent_chore || tapped
    completed_at = parse_client_time(params[:client_completed_at]) || Time.current

    completion = ChoreCompletion.create!(
      chore:          credit,
      sub_chore_id:   (tapped.id if tapped.id != credit.id),
      user:           current_user,
      completed_at:   completed_at,
      day_key:        ChoreDay.current(current_user, at: completed_at),
      payout_skipped: true,
      skipped_reason: "Marked done by someone outside the household",
      anonymous:      true,
      note:           params[:note].to_s,
    )
    ChoreBroadcaster.broadcast_changes!(current_user, credit, actor_tab_id: params[:tab_id])
    ChoreBroadcaster.broadcast_changes!(current_user, tapped, actor_tab_id: params[:tab_id]) if tapped.id != credit.id
    render json: response_payload(tapped, completion).merge(anonymous: true), status: :created
  end

  def create
    chore = current_user.accessible_chores.find(params[:chore_id])
    completed_at = parse_client_time(params[:client_completed_at]) || Time.current

    result = ChoreCompleter.new(chore, current_user, at: completed_at).call

    # When a pending push was edited on the History page before being
    # sent (note, multipliers, hot_pick), the queued POST replays those
    # overrides here. Apply post-create so paid_pebbles stays driven by
    # ChoreCompleter — multipliers / hot_pick are historical record
    # only, mirroring the update path.
    apply_create_overrides!(result.completion) if result.completion

    render json: response_payload(chore, result.completion).merge(
      skipped:        result.skipped?,
      skipped_reason: result.skipped_reason,
      achieved_goals: result.achieved_goals.map { |g| { name: g.name, pebbles: g.awarded_pebbles.to_i } },
    ), status: :created
  end

  def update
    completion = current_user.chore_completions.find(params[:id])
    prev_day_key = completion.day_key
    prev_payout_skipped = completion.payout_skipped
    attrs = completion_params
    # `hot_pick` lives in the jsonb metadata blob — merge rather than
    # permit metadata wholesale (we don't want the client setting
    # arbitrary keys). Multipliers are flat columns, already permitted
    # via `completion_params`; they're stored as historical record and
    # never auto-applied to paid_pebbles.
    raw = params.require(:chore_completion)
    if raw.key?(:hot_pick)
      flag = ActiveModel::Type::Boolean.new.cast(raw[:hot_pick])
      attrs[:metadata] = (completion.metadata || {}).merge("hot_pick" => flag)
    end
    if completion.update(attrs)
      # Moving a completion across days (e.g. History edit: today→yesterday)
      # or flipping payout_skipped invalidates the streak counter — rebuild
      # from scratch like the destroy paths do. Without this, the streak
      # could keep counting yesterday's day_key as today's.
      if completion.day_key != prev_day_key || completion.payout_skipped != prev_payout_skipped
        rebuild_streak(completion.chore, prev_day_key)
      end
      ChoreBroadcaster.broadcast_changes!(current_user, completion.chore)
      render json: response_payload(completion.chore, completion).merge(balance: current_user.chore_balance)
    else
      render json: { errors: completion.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # Two destroy paths share this action: the per-chore undo (last
  # completion today, via /chores/items/:chore_id/completion) and the
  # history-page row delete (via /chores/completions/:id). The latter
  # is manager-only — members can't rewrite history.
  def destroy
    if params[:chore_id]
      destroy_last_today
    else
      return render(json: { error: "Only household managers can edit history." }, status: :forbidden) unless current_user.can_manage_chores?

      destroy_by_id
    end
  end

  private

  def require_chore_manager!
    return if current_user.can_manage_chores?

    render json: { error: "Only household managers can edit history." }, status: :forbidden
  end

  def destroy_last_today
    tapped = current_user.accessible_chores.unscope(where: :archived_at).find(params[:chore_id])
    day = ChoreDay.current(current_user)

    # Per the sharing spec: household + personal/assigned each undo only
    # the CURRENT user's record. Household never removes another user's
    # completion (their record is theirs to undo). Anonymous
    # completions are administrative audits — the tap-undo gesture
    # never targets them; they're only edited via the History page.
    # Sub-chore card undo: find by sub_chore_id (not chore_id — that
    # would catch any sibling sub-chore's parent-credited row).
    column, value = tapped.sub_chore? ? [:sub_chore_id, tapped.id] : [:chore_id, tapped.id]
    completion = current_user.chore_completions
      .credited
      .where(column => value, day_key: day)
      .order(completed_at: :desc).first

    if completion
      credit_chore = completion.chore
      completion.destroy!
      rebuild_streak(credit_chore, day)
      ChoreBroadcaster.broadcast_changes!(current_user, credit_chore, actor_tab_id: params[:tab_id])
      ChoreBroadcaster.broadcast_changes!(current_user, tapped, actor_tab_id: params[:tab_id]) if tapped.id != credit_chore.id
      render json: response_payload(tapped, nil)
    else
      render json: { error: "no completion to undo" }, status: :not_found
    end
  end

  def destroy_by_id
    completion = current_user.chore_completions.find(params[:id])
    chore = completion.chore
    day = completion.day_key
    completion.destroy!
    rebuild_streak(chore, day)
    ChoreBroadcaster.broadcast_changes!(current_user, chore, actor_tab_id: params[:tab_id])
    # today_earnings is the canonical value behind the header pill on
    # every page. Always emit it — even on deletes where today's
    # earnings drop if the removed completion was on today's day_key —
    # so the client never has to guess.
    today = ChoreDay.current(current_user)
    today_earnings = current_user.chore_completions.where(day_key: today).sum(:paid_pebbles)
    render json: {
      balance:        current_user.chore_balance,
      today_earnings: today_earnings,
    }
  end

  # Pending-push overrides accepted on create. Only the keys present
  # in the body are touched — a vanilla queued POST (no overrides) is
  # a no-op here.
  def apply_create_overrides!(completion)
    raw = params[:chore_completion]
    return if raw.blank?

    overrides = {}
    overrides[:note]             = raw[:note].to_s             if raw.key?(:note)
    overrides[:hot_multiplier]   = raw[:hot_multiplier].to_f   if raw.key?(:hot_multiplier)
    overrides[:streak_multiplier] = raw[:streak_multiplier].to_f if raw.key?(:streak_multiplier)
    # Legacy clients (or queued requests written before the column
    # rename) may still ship total_multiplier; treat it as the streak
    # signal so the override path keeps working.
    overrides[:streak_multiplier] = raw[:total_multiplier].to_f if !overrides.key?(:streak_multiplier) && raw.key?(:total_multiplier)
    if raw.key?(:paid_pebbles)
      amount = raw[:paid_pebbles].to_i
      overrides[:paid_pebbles]   = amount
      overrides[:payout_skipped] = amount.zero?
    end
    metadata_updates = {}
    if raw.key?(:hot_pick)
      metadata_updates["hot_pick"] = ActiveModel::Type::Boolean.new.cast(raw[:hot_pick])
    end
    if raw.key?(:note_values)
      values = raw[:note_values]
      values = values.to_unsafe_h if values.respond_to?(:to_unsafe_h)
      metadata_updates["note_values"] = (values || {}).to_h.transform_keys(&:to_s)
    end
    if metadata_updates.any?
      overrides[:metadata] = (completion.metadata || {}).merge(metadata_updates)
    end
    return if overrides.empty?

    completion.update!(overrides)
  end

  def completion_params
    perms = params.require(:chore_completion).permit(
      :paid_pebbles, :completed_at, :payout_skipped, :note,
      :hot_multiplier, :streak_multiplier, :total_multiplier
    )
    # Legacy `total_multiplier` is the same signal as streak_multiplier
    # after the rename; route it through so older queued requests keep
    # working.
    if perms.key?(:total_multiplier) && !perms.key?(:streak_multiplier)
      perms[:streak_multiplier] = perms.delete(:total_multiplier)
    else
      perms.delete(:total_multiplier)
    end
    # If user changed the timestamp, recompute the chore-day key so
    # streaks / hot-pick joins all stay correct.
    if perms[:completed_at].present?
      perms[:day_key] = ChoreDay.current(current_user, at: Time.zone.parse(perms[:completed_at].to_s))
    end
    perms
  end

  # Accept the client's local click timestamp for offline-queued
  # completions. An action taken at 2pm offline gets recorded as 2pm
  # when it finally syncs at 3pm — or 3 weeks later, if that's how long
  # the queue had to wait for connectivity / re-auth.
  #
  # Only sanity check: reject obvious future timestamps (clock skew >5m).
  # We do NOT cap historical depth — the offline queue must never lose
  # an event, even if syncing weeks late.
  def parse_client_time(raw)
    return nil if raw.blank?

    t = Time.iso8601(raw.to_s)
    return nil if t > 5.minutes.from_now

    t
  rescue ArgumentError
    nil
  end

  # After a destroy, recompute the streak from scratch using the most
  # recent paid completion. A user undoing today's completion shouldn't
  # leave a phantom-incremented streak behind.
  def rebuild_streak(chore, _day)
    streak = ChoreStreak.find_by(user_id: current_user.id, chore_id: chore.id)
    return if streak.blank?

    last_paid = current_user.chore_completions
      .where(chore_id: chore.id, payout_skipped: false, anonymous: false)
      .order(completed_at: :desc).first

    if last_paid.nil?
      streak.destroy
      return
    end

    # Walk backward day-by-day from the last paid completion; count
    # consecutive days with at least one paid (non-anonymous) completion.
    cursor = last_paid.day_key
    count = 0
    loop do
      had = current_user.chore_completions
        .exists?(chore_id: chore.id, day_key: cursor, payout_skipped: false, anonymous: false)
      break unless had

      count += 1
      cursor -= 1
    end

    streak.update!(
      current_streak:     count,
      last_completed_day: last_paid.day_key,
      longest_streak:     [streak.longest_streak, count].max,
    )
  end

  # Unified payload — every mutation returns the canonical Chore JSON
  # (the same shape used by /sync, /state, page bootstrap). The client
  # `ChoreStore` upserts directly from `chore`, so views re-render with
  # zero divergence between mutation paths.
  def response_payload(chore, completion)
    day = ChoreDay.current(current_user)
    today_earnings = current_user.chore_completions.where(day_key: day).sum(:paid_pebbles)

    {
      chore:          ChoreSerializer.new(chore, viewer: current_user, day: day).as_json,
      balance:        current_user.chore_balance,
      today_earnings: today_earnings,
      paid:           completion&.paid_pebbles,
      server_ts:      Time.current.iso8601(3),
    }
  end
end
