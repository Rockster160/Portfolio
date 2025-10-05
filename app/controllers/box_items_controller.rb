class BoxItemsController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authorize_user_or_guest

  # def index
  #   items = current_box_items
  #   items = items.with_deleted if params[:with_deleted] == "true"
  #   serialize items
  # end

  # def show
  #   serialize current_item
  # end

  # def create
  #   create_params = box_item_params
  #   # Add any custom parsing logic for BoxItem if needed
  #   new_item = current_item(:soft) || current_box_items.new
  #   new_item.update(create_params.merge(deleted_at: nil, sort_order: nil))
  #   trigger(:added, new_item)
  #   serialize new_item
  # end

  # def update
  #   current_item.update(box_item_params)
  #   trigger(:changed, current_item)
  #   serialize current_item
  # end

  # def destroy
  #   current_item.soft_destroy unless current_item.permanent?
  #   trigger(:removed, current_item)
  #   serialize current_item
  # end

  # private

  # def box_item_params
  #   params.require(:box_item).permit(:name, :description, :other_attributes)
  # end

  # def current_item(type=nil)
  #   # Implement logic to find current box item
  #   current_box_items.find(params[:id])
  # end

  # def current_box_items
  #   # Implement logic to get box items for current box
  #   current_box.box_items
  # end

  # def current_box
  #   # Implement logic to get current box
  #   current_user.boxes.find(params[:box_id])
  # end
end
