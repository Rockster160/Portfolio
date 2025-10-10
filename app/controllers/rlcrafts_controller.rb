class RlcraftsController < ApplicationController
  skip_before_action :verify_authenticity_token

  def show
    @locations = RlcraftMapLocation.all
    @location_types = RlcraftMapLocation.location_types
  end

  def update
    if params[:id].present?
      location = RlcraftMapLocation.find(params[:id])

      if params[:_destroy] == "true"
        location.destroy
      else
        location.update(location_params)
      end
    else
      location = RlcraftMapLocation.create(location_params)
    end

    render json: location.to_graphable_data
  end

  private

  def location_params
    params.require(:location).permit(
      :x_coord,
      :y_coord,
      :title,
      :location_type,
      :description,
    )
  end
end
