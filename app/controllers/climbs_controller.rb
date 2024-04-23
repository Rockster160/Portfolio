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
    Time.use_zone(current_user.timezone) {
      @climb = current_user.climbs.create(climb_params)
    }

    redirect_to :climbs
  end

  def mark
    Time.use_zone(current_user.timezone) {
      @climb = current_user.climbs.find_by(created_at: Time.current.all_day)
      @climb ||= current_user.climbs.create(timestamp: Time.current)

      @climb.update(data: [@climb.data, params[:v_index]].compact_blank.join(" "))
    }

    render json: { score: @climb.score }
  end

  def update
    Time.use_zone(current_user.timezone) {
      @climb = current_user.climbs.find(params[:id]).update(climb_params)
    }

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
