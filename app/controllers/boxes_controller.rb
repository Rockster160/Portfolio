class BoxesController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authorize_user_or_guest

  def index
    @boxes = current_user.boxes
    # Query needs to be first!
    @boxes = @boxes.query(params[:q]) if params[:q].present?

    # Add option to filter items vs boxes - can include containers with include_containers param
    @boxes = @boxes.where(empty: true) unless params[:include_containers].present?
    @boxes = @boxes.within(params[:within]) if params[:within].present?

    # Include hierarchy_ids if with_ancestors is requested
    if params[:with_ancestors].present?
      serialize @boxes, include_hierarchy_ids: true
    else
      serialize @boxes
    end
  end

  def show
    @open = current_box.level
    render partial: "inventory_management/box", locals: { box: current_box }
  end

  def batch
    ids = params[:ids]&.split(",")&.map(&:strip)
    return render json: { data: {} } if ids.blank?

    result = {}
    ids.each do |id|
      box = current_user.boxes.find_by(param_key: id) || current_user.boxes.find_by(id: id)
      next unless box

      result[id] = box.contents.map { |child|
        {
          id: child.id,
          param_key: child.param_key,
          name: child.name,
          notes: child.notes,
          description: child.description,
          hierarchy: child.hierarchy,
          parent_key: child.parent_key,
          empty: child.empty,
          sort_order: child.sort_order
        }
      }
    end

    render json: { data: result }
  end

  private

  def current_box
    current_user.boxes.find(params[:id])
  end
end
