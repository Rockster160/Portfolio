class InventoryManagementController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authorize_user_or_guest

  layout "quick_actions"

  def show
    @boxes = current_user.boxes.where(parent_id: nil).ordered
  end

  def box # boxes#show
    @box = current_user.boxes.find(params[:id])
    @boxes = [@box]
    @crumbs = @box.hierarchy_data || []
    @open = 1

    render :show
  end

  def create
    box = current_user.boxes.create!(box_params)

    serialize box
  end

  def update
    if params[:box_id].present?
      box = current_user.boxes.find(params[:box_id])
      box.update!(box_params)
    end

    if params[:child_ids].present?
      parent_scope = (
        if params[:parent_id].present?
          current_user.boxes.where(parent_id: params[:parent_id])
        else
          current_user.boxes.where(parent_id: nil)
        end
      )
      boxes = parent_scope.where(id: params[:child_ids])
      ordered_boxes = params[:child_ids].map { |id| boxes.detect { |b| b.id == id.to_i } }.compact

      box_count = ordered_boxes.size
      ordered_boxes.each_with_index do |box, idx|
        box.update!(sort_order: box_count - idx)
      end
    end

    serialize box
  end

  def destroy
    box = current_user.boxes.find(params[:box_id])
    box.destroy!

    serialize box, merge: { deleted: true }
  end

  private

  def box_params
    params.permit(:name, :notes, :description, :parent_id).tap { |whitelist|
      whitelist[:parent_id] = nil if whitelist[:parent_id].present? && current_user.boxes.where(id: whitelist[:parent_id]).empty?
    }
  end
end
