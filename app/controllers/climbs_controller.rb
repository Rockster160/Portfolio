class ClimbsController < ApplicationController
  def index
    @climbs = current_user.climbs.order(created_at: :desc)
  end

  def new
    @climb = Climb.new

    render :form
  end

  def create
    @climb = current_user.climbs.create(climb_params)

    redirect_to :climbs
  end

  def destroy
    current_user.climbs.find(params[:id]).destroy

    redirect_to :climbs
  end

  private

  def climb_params
    params.require(:climb).permit(:data)
  end
end
