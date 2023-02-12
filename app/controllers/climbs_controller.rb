class ClimbsController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authorize_user

  def index
    @climbs = current_user.climbs.order(timestamp: :desc)
  end

  def new
    @climb = Climb.new

    render :form
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

  def update
    Time.use_zone(current_user.timezone) {
      @climb = current_user.climbs.update(climb_params)
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
