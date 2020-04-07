class RlcraftsController < ApplicationController
  skip_before_action :verify_authenticity_token

  def show
    @locations = RlcraftMapLocation.all
  end

  def update
    new_location = RlcraftMapLocation.create(location_params)

    render json: new_location.to_graphable_data
  end

  private

  def location_params
    params.require(:location).permit(
      :x_coord,
      :y_coord,
      :title,
      :location_type,
      :description
    )
  end

end
