class ClimbsController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authorize_user_or_guest

  def index
    @climbs = current_user.climbs.not_empty.order(timestamp: :desc)
    @best_climb = @climbs.best
  end

  def new
    @climb = current_user.climbs.create

    redirect_to [:edit, @climb]
  end

  def edit
    @climb = current_user.climbs.find(params[:id])

    render :form
  end

  def create
    @climb = current_user.climbs.create(climb_params)

    redirect_to :climbs
  end

  def mark
    @climb = current_user.climbs.order(created_at: :desc).find_by(created_at: Time.current.all_day)
    @climb ||= current_user.climbs.create(timestamp: Time.current)
    @climb.add(params[:v_index])

    data = {
      last: params[:v_index],
      score: @climb.score,
      climbs: @climb.scores,
      recent_avg: current_user.climbs.recent_avg.round(2),
      alltime_avg: current_user.climbs.alltime_avg.round(2),
    }

    jil_trigger(:climbing, data)

    render json: data.map { |key, value| "#{key}: #{value}" }.join("\n")
  end

  def update
    @climb = current_user.climbs.find(params[:id]).update(climb_params)

    redirect_to :climbs
  end

  def destroy
    current_user.climbs.find(params[:id]).destroy

    redirect_to :climbs
  end

  private

  def climb_params
    params.require(:climb).permit(
      :data,
      :timestamp,
    )
  end
end
