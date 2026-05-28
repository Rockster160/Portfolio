class ChoreCompletionsController < ApplicationController
  before_action :authorize_user_or_guest

  def create
    chore = current_user.accessible_chores.find(params[:chore_id])
    completed_at = parse_client_time(params[:client_completed_at]) || Time.current

    result = ChoreCompleter.new(chore, current_user, at: completed_at).call

    render json: response_payload(chore, result.completion).merge(
      skipped: result.skipped?,
      skipped_reason: result.skipped_reason,
      awarded_achievements: result.awarded.map { |a| { name: a.chore_achievement.name, pebbles: a.awarded_pebbles } },
    ), status: :created
  end

  # Two destroy paths share this action: the per-chore undo (last
  # completion today, via /chores/items/:chore_id/completion) and the
  # history-page row delete (via /chores/completions/:id).
  def destroy
    if params[:chore_id]
      destroy_last_today
    else
      destroy_by_id
    end
  end

  def update
    completion = current_user.chore_completions.find(params[:id])
    if completion.update(completion_params)
      ChoreBroadcaster.broadcast_changes!(current_user, completion.chore)
      render json: response_payload(completion.chore, completion).merge(balance: current_user.chore_balance)
    else
      render json: { errors: completion.errors.full_messages }, status: :unprocessable_entity
    end
  end

  private

  def destroy_last_today
    chore = current_user.accessible_chores.unscope(where: :archived_at).find(params[:chore_id])
    day = ChoreDay.current(current_user)

    # Per the sharing spec: household + personal/assigned each undo only
    # the CURRENT user's record. Household never removes another user's
    # completion (their record is theirs to undo).
    completion = current_user.chore_completions
      .where(chore_id: chore.id, day_key: day)
      .order(completed_at: :desc).first

    if completion
      completion.destroy!
      rebuild_streak(chore, day)
      ChoreBroadcaster.broadcast_changes!(current_user, chore, actor_tab_id: params[:tab_id])
      render json: response_payload(chore, nil)
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
    render json: { balance: current_user.chore_balance }
  end

  def completion_params
    perms = params.require(:chore_completion).permit(:paid_pebbles, :completed_at, :payout_skipped, :note)
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
    return nil if t > Time.current + 5.minutes

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
      .where(chore_id: chore.id, payout_skipped: false)
      .order(completed_at: :desc).first

    if last_paid.nil?
      streak.destroy
      return
    end

    # Walk backward day-by-day from the last paid completion; count
    # consecutive days with at least one paid completion.
    cursor = last_paid.day_key
    count = 0
    loop do
      had = current_user.chore_completions
        .where(chore_id: chore.id, day_key: cursor, payout_skipped: false)
        .exists?
      break unless had

      count += 1
      cursor -= 1
    end

    streak.update!(
      current_streak: count,
      last_completed_day: last_paid.day_key,
      longest_streak: [streak.longest_streak, count].max,
    )
  end

  def response_payload(chore, completion)
    day = ChoreDay.current(current_user)
    user_ids = chore.share_household? ? household_user_ids_for_chore(chore) : [current_user.id]
    last = ChoreCompletion
      .where(chore_id: chore.id, user_id: user_ids)
      .order(completed_at: :desc).first
    completions_today = ChoreCompletion
      .where(chore_id: chore.id, user_id: user_ids, day_key: day).count
    today_earnings = current_user.chore_completions.where(day_key: day).sum(:paid_pebbles)

    {
      chore_id: chore.id,
      balance: current_user.chore_balance,
      today_earnings: today_earnings,
      completions_today: completions_today,
      last_completion: last&.completed_at&.iso8601(3),
      last_completed_at: last&.completed_at&.iso8601(3),
      paid: completion&.paid_pebbles,
      server_ts: Time.current.iso8601(3),
    }
  end

  def household_user_ids_for_chore(chore)
    Chore.household_user_ids_for(chore.created_by_user_id)
  end
end
