class BoxesController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authorize_user_or_guest

  # def index
  #   @boxes = current_user.ordered_boxes
  #   serialize @boxes, with_deleted: params[:with_deleted] == "true"
  # end

  def show
    render partial: "inventory_management/box", locals: { box: current_box, preload: true }
  end

  # def reorder
  #   params[:box_ids].each_with_index do |box_id, idx|
  #     current_user.user_boxes.find_by(box_id: box_id).update(sort_order: idx)
  #   end
  #   serialize current_user.ordered_boxes
  # end

  # def order_items
  #   @box = current_box
  #   params[:item_ids].each_with_index do |id, index|
  #     @box.box_items.find(id).update(position: index)
  #   end
  #   serialize @box
  # end

  # def create
  #   new_box = current_user.boxes.create(box_params)
  #   new_box.persisted? && current_user.user_boxes.create(
  #     box_id: new_box.id, is_owner: true,
  #     default: params[:default] == "true"
  #   )
  #   trigger(:create, new_box)
  #   serialize new_box
  # end

  # def update
  #   @box = current_box
  #   trigger(:changed, @box) if @box.update(box_params)
  #   serialize @box
  # end

  private

  # def box_params
  #   params.require(:box).permit(:name, :description, :other_attributes)
  # end

  def current_box
    current_user.boxes.find(params[:id])
  end

  # def current_user
  #   # Implement current_user logic or use existing method
  #   super
  # end
end
