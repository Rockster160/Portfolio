# Running countdowns, for the Live Activities the app starts itself and for
# the controls on them.
class Api::Ios::TimersController < Api::Ios::BaseController
  # Every timer this phone is sent, a household one included: the app ends
  # any Live Activity or alarm missing from this list.
  def index
    timers = Timer.live.countdown.where(user_id: current_user.chore_household_user_ids)
    timers = timers.where("started_at IS NOT NULL OR paused_at IS NOT NULL OR fired_at IS NOT NULL")
    timers = timers.order(:end_at).select { |timer|
      timer.user_id == current_user.id || Buddy::Timers.audience(timer).include?(current_user)
    }
    render json: timers.map { |timer| AppPush::Timers.wire(timer) }
  end

  def pause
    timer.pause!
    timer.broadcast(reason: :paused)
    render json: AppPush::Timers.wire(timer.reload)
  end

  def resume
    timer.resume!
    timer.broadcast(reason: :resumed)
    render json: AppPush::Timers.wire(timer.reload)
  end

  def confirm
    timer.confirm!
    render json: AppPush::Timers.wire(timer.reload)
  end

  def cancel
    Buddy::Timers.stop!(timer)
    render json: AppPush::Timers.wire(timer.reload)
  end

  private

  def timer
    @timer ||= (
      current_user.timers.live.find_by(id: params[:id]) ||
        Buddy::Timers.reachable(current_user, params[:id]) ||
        raise(ActiveRecord::RecordNotFound)
    )
  end
end
