class ChoreCompletionsController < ApplicationController
  before_action :authorize_user_or_guest
  before_action :require_chore_manager!, only: [:update]

  # POST /chores/items/:chore_id/anonymous_completion
  # Two modes, chosen by whether `credit_user_id` is present:
  #   * blank → anonymous. Credits no household member; user_id captures
  #     the recorder; display-side ignores the row (see ChoreCompletion#credited).
  #   * household member id → run the full ChoreCompleter pipeline as
  #     that user. Points, streak, Jil triggers all fire under their name.
  #     Any household member may credit any other member here.
  def anonymous_completion
    tapped = current_user.accessible_chores.find(params[:chore_id])
    completed_at = parse_client_time(params[:client_completed_at]) || Time.current
    credit_user = resolve_credit_user(params[:credit_user_id])

    if credit_user
      # Crediting a member from a container's card means "they did their
      # half" — same redirect as an ordinary tap, resolved for the person
      # being credited rather than the one recording it. The anonymous
      # branch below deliberately stays on the container: nobody is named,
      # so there is no whose-sub to answer.
      tapped = tapped.completion_leaf_for(credit_user)
      result = ChoreCompleter.new(
        tapped, credit_user,
        at:          completed_at,
        note:        params[:note].presence,
        # Credit goes to them; the trigger has to reach whoever marked it too,
        # or a personal chore marked done for a housemate runs THEIR
        # automations and none of the recorder's.
        recorded_by: current_user
      ).call
      # ChoreCompleter already broadcasts against the credited user; also
      # broadcast to the recorder so their device refreshes (household
      # channels are per-user, and the recorder may not be the actor).
      if credit_user.id != current_user.id
        related = (tapped.parent_chore if tapped.sub_chore?)
        ChoreBroadcaster.broadcast_changes!(current_user, tapped, related: related, actor_tab_id: params[:tab_id])
      end
      render json: response_payload(tapped, result.completion).merge(
        skipped:        result.skipped?,
        skipped_reason: result.skipped_reason,
        achieved_goals: result.achieved_goals.map { |g| { name: g.name, pebbles: g.awarded_pebbles.to_i } },
        credited_to:    { id: credit_user.id, username: credit_user.username },
      ), status: :created
      return
    end

    # Anonymous sub-chore taps record chore_id = leaf just like a
    # credited tap; parent_chore_id auto-syncs from chore.parent_chore_id
    # so the parent's shared cooldown / carryover queries still see the
    # tap.
    completion = ChoreCompletion.create!(
      chore:          tapped,
      user:           current_user,
      completed_at:   completed_at,
      day_key:        ChoreDay.current(current_user, at: completed_at),
      payout_skipped: true,
      skipped_reason: "Marked done by someone outside the household",
      anonymous:      true,
      note:           params[:note].to_s,
    )
    related = (tapped.parent_chore if tapped.sub_chore?)
    ChoreBroadcaster.broadcast_changes!(current_user, tapped, related: related, actor_tab_id: params[:tab_id])
    render json: response_payload(tapped, completion).merge(anonymous: true), status: :created
  end

  def create
    tapped = current_user.accessible_chores.find(params[:chore_id])
    # A chore split into per-person sub-chores is tapped through its
    # container — that's the card the Hot strip and the grid show. Record
    # against this person's own sub so their card reads done too; a
    # completion written on the container credits neither half (see
    # Chore#completion_leaf_for). The payout is unchanged: ChoreCompleter
    # still credits the parent's streak and falls back to the parent's hot
    # multiplier.
    chore = tapped.completion_leaf_for(current_user)
    completed_at = parse_client_time(params[:client_completed_at]) || Time.current

    # Queue-first replays POST the same body twice if the response of
    # the first attempt never made it back. Dedupe by client_mutation_id:
    # if we already have a completion for this user with that id, return
    # the same shape the original POST returned. No new row, no double
    # payout, no double Jil trigger.
    mutation_id = params[:client_mutation_id].presence
    if mutation_id && (existing = current_user.chore_completions.find_by(client_mutation_id: mutation_id))
      render json: response_payload(existing.chore, existing).merge(
        skipped:        existing.payout_skipped,
        skipped_reason: existing.skipped_reason,
        achieved_goals: [],
        deduped:        true,
      ), status: :ok
      return
    end

    result = ChoreCompleter.new(chore, current_user, at: completed_at).call

    # When a pending push was edited on the History page before being
    # sent (note, multipliers, hot_pick), the queued POST replays those
    # overrides here. Apply post-create so paid_pebbles stays driven by
    # ChoreCompleter — multipliers / hot_pick are historical record
    # only, mirroring the update path.
    apply_create_overrides!(result.completion) if result.completion
    result.completion&.update_column(:client_mutation_id, mutation_id) if mutation_id

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
    # `skipped_reason` is the system's explanation for the flag, never
    # client text: restoring a payout drops the stale reason ("Cooldown
    # — resets at end of day" on a row that now paid out reads as a
    # lie), and skipping by hand from the History modal says so.
    if attrs.key?(:payout_skipped) && attrs[:payout_skipped] != prev_payout_skipped
      attrs[:skipped_reason] = (attrs[:payout_skipped] ? "Skipped by hand" : nil)
    end
    if completion.update(attrs)
      # Moving a completion across days (e.g. History edit: today→yesterday)
      # or flipping payout_skipped invalidates the streak counter — rebuild
      # from scratch like the destroy paths do. Without this, the streak
      # could keep counting yesterday's day_key as today's.
      if completion.day_key != prev_day_key || completion.payout_skipped != prev_payout_skipped
        ChoreStreak.rebuild_for!(current_user, completion.chore)
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

  # Anonymous-modal "Credit to" selector. Returns the target user only
  # when the id belongs to the same household — silently falls back to
  # the anonymous path otherwise (the modal shouldn't have offered a
  # non-household id in the first place; a stale form is treated as if
  # the user picked "Nobody").
  def resolve_credit_user(raw)
    id = raw.to_i
    return nil if id.zero?
    return nil unless current_user.chore_household_user_ids.include?(id)

    User.find_by(id: id)
  end

  def require_chore_manager!
    return if current_user.can_manage_chores?

    render json: { error: "Only household managers can edit history." }, status: :forbidden
  end

  def destroy_last_today
    tapped = current_user.accessible_chores.unscope(where: :archived_at).find(params[:chore_id])
    day = ChoreDay.current(current_user)

    # Queue-first undo: the client carries the client_mutation_id of the
    # specific create it's undoing. Targets THAT row directly, not "the
    # most recent today" — otherwise a replayed undo could delete a
    # later, legitimate completion. When the target is already gone
    # (first undo flushed and we're replaying), return 200 idempotently.
    target_id = params[:target_client_mutation_id].presence
    if target_id
      completion = current_user.chore_completions.find_by(client_mutation_id: target_id)
      if completion.nil?
        render json: response_payload(tapped, nil).merge(deduped: true)
        return
      end

      leaf = completion.chore
      day_at_delete = completion.day_key
      completion.destroy!
      ChoreStreak.rebuild_for!(current_user, leaf)
      related = (leaf.parent_chore if leaf.sub_chore?)
      ChoreBroadcaster.broadcast_changes!(current_user, leaf, related: related, actor_tab_id: params[:tab_id])
      # The leaf, not the tapped chore: a container tap records against the
      # sub-chore, and this broadcast skips the actor's own tab, so the
      # response is the only thing that clears the sub-chore's done state
      # on the device that undid it.
      render json: response_payload(leaf, nil)
      return
    end

    # Per the sharing spec: household + personal/assigned each undo only
    # the CURRENT user's record. Household never removes another user's
    # completion (their record is theirs to undo). Anonymous
    # completions are administrative audits — the tap-undo gesture
    # never targets them; they're only edited via the History page.
    # Mirror the create-side redirect: a tap on a container was recorded
    # against this person's own sub-chore, so that's the row to undo.
    # Without it, undoing a Hot-strip container tap finds nothing.
    target = tapped.completion_leaf_for(current_user)
    completion = current_user.chore_completions
      .credited
      .where(chore_id: target.id, day_key: day)
      .order(completed_at: :desc).first

    if completion
      completion.destroy!
      ChoreStreak.rebuild_for!(current_user, target)
      related = (target.parent_chore if target.sub_chore?)
      ChoreBroadcaster.broadcast_changes!(current_user, target, related: related, actor_tab_id: params[:tab_id])
      render json: response_payload(target, nil)
    else
      render json: { error: "no completion to undo" }, status: :not_found
    end
  end

  def destroy_by_id
    completion = current_user.chore_completions.find(params[:id])
    chore = completion.chore
    day = completion.day_key
    completion.destroy!
    ChoreStreak.rebuild_for!(current_user, chore)
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
    # A skipped completion pays nothing — the balance is a plain
    # SUM(paid_pebbles), so a skipped row carrying an amount would pay
    # out while the history renders it as "(skipped)".
    if perms.key?(:payout_skipped)
      perms[:payout_skipped] = ActiveModel::Type::Boolean.new.cast(perms[:payout_skipped])
      perms[:paid_pebbles] = 0 if perms[:payout_skipped]
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

  # Streak rebuild after a destroy now lives on ChoreStreak.rebuild_for! so the
  # app's tap-undo and Buddy's undo share ONE implementation.

  # Unified payload — every mutation returns the canonical Chore JSON
  # (the same shape used by /sync, /state, page bootstrap). The client
  # `ChoreStore` upserts directly from `chore`, so views re-render with
  # zero divergence between mutation paths.
  def response_payload(chore, completion)
    day = ChoreDay.current(current_user)
    today_earnings = current_user.chore_completions.where(day_key: day).sum(:paid_pebbles)
    followers = after_chore_followers(chore).map { |f|
      ChoreSerializer.new(f, viewer: current_user, day: day).as_json
    }

    {
      chore:          ChoreSerializer.new(chore, viewer: current_user, day: day).as_json,
      chores:         followers,
      balance:        current_user.chore_balance,
      today_earnings: today_earnings,
      paid:           completion&.paid_pebbles,
      server_ts:      Time.current.iso8601(3),
    }
  end

  # `:after_chore` followers of the chore just completed (or un-completed).
  # Their today_visible / due_today flip the moment the anchor is tapped,
  # but they get no completion row and no `updated_at` bump — and this
  # response is the ONLY channel the acting device has, since
  # ChoreBroadcaster skips the actor's own tab. Without them, a same-day
  # "Go get mail → Go through mail" doesn't surface until the next full
  # /chores/sync (foreground, reload, reconnect, or the 4am rollover).
  # ChoresController#after_chore_follower_ids does the same thing for the
  # sync delta.
  #
  # A container tap is recorded against the leaf, and a parent-anchored
  # follower fires on ANY sub-chore of the parent, so both ids count as
  # anchors here — mirroring the `chore_id OR parent_chore_id` in
  # Chore#lookup_anchor_last_day.
  def after_chore_followers(chore)
    current_user.accessible_chores.following([chore.id, chore.parent_chore_id]).to_a
  end
end
