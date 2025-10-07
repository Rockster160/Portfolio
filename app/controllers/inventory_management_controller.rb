class InventoryManagementController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authorize_user_or_guest

  layout "quick_actions"

  def show
    @boxes = current_user.boxes.where(parent_id: nil).ordered
  end

  def create
    box = current_user.boxes.create!(box_params)

    serialize box
  end

  def update
    box = current_user.boxes.find(params[:box_id])
    box.update!(box_params)

    serialize box
  end

  # def destroy
  # end

  private

  def box_params
    params.permit(:name, :notes, :description, :parent_id).tap { |whitelist|
      if whitelist[:parent_id].present? && current_user.boxes.where(id: whitelist[:parent_id]).empty?
        whitelist[:parent_id] = nil
      end
    }
  end
end
