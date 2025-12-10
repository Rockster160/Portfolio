class InventoryManagementController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authorize_user_or_guest

  layout "quick_actions"

  def show
    @boxes = current_user.boxes.where(parent_key: nil).ordered
  end

  def box # boxes#show
    @box = current_user.boxes.from_key(params[:id])
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
        if params[:parent_key].present?
          current_user.boxes.where(parent_key: params[:parent_key])
        else
          current_user.boxes.where(parent_key: nil)
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
    box.parent.update!(empty: true) if box.parent && box.parent.boxes.empty?

    serialize box, merge: { deleted: true }
  end

  private

  def box_params
    params.permit(:name, :notes, :description, :parent_key).tap { |whitelist|
      whitelist[:parent_key] = nil if whitelist[:parent_key].present? && current_user.boxes.where(param_key: whitelist[:parent_key]).empty?
    }
  end
end
