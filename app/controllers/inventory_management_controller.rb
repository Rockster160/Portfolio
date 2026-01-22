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

      # When dropping INTO a box, set sort_order to appear at top
      # (child_ids may be incomplete due to lazy loading)
      if params[:insert_at_top].present?
        siblings = box.parent&.boxes || current_user.boxes.where(parent_key: nil)
        max_sort = siblings.maximum(:sort_order) || 0
        box.update!(sort_order: max_sort + 1)
      end
    end

    # Skip child_ids sorting when insert_at_top is used (lazy loading means child_ids is incomplete)
    # child_ids contains param_keys (not numeric ids) since Box.primary_key = "param_key"
    if params[:child_ids].present? && !params[:insert_at_top].present?
      parent_scope = (
        if params[:parent_key].present?
          current_user.boxes.where(parent_key: params[:parent_key])
        else
          current_user.boxes.where(parent_key: nil)
        end
      )
      boxes = parent_scope.where(param_key: params[:child_ids])
      ordered_boxes = params[:child_ids].map { |key| boxes.detect { |b| b.param_key == key } }.compact

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

  def export
    boxes = if params[:within].present?
      current_user.boxes.within(params[:within])
    else
      current_user.boxes
    end

    format = params[:format] || "csv"

    case format
    when "json"
      data = build_nested_export(boxes)
      respond_to do |f|
        f.json { render json: { data: data } }
        f.html {
          send_data data.to_json,
            filename: "inventory_export_#{Time.current.strftime('%Y%m%d')}.json",
            type: "application/json"
        }
      end
    else # csv
      csv_data = generate_csv_export(boxes)
      respond_to do |f|
        f.csv {
          send_data csv_data,
            filename: "inventory_export_#{Time.current.strftime('%Y%m%d')}.csv",
            type: "text/csv"
        }
        f.html {
          send_data csv_data,
            filename: "inventory_export_#{Time.current.strftime('%Y%m%d')}.csv",
            type: "text/csv"
        }
        f.json { render json: { data: csv_data } }
      end
    end
  end

  def import
    file = params[:file]
    format = params[:format] || (file&.original_filename&.end_with?(".json") ? "json" : "csv")
    parent_key = params[:parent_key]

    result = InventoryImporter.new(current_user, format: format, parent_key: parent_key).import(file)

    if result[:success]
      render json: { data: { imported: result[:count], boxes: result[:boxes].map(&:serialize) } }
    else
      render json: { error: result[:error] }, status: :unprocessable_entity
    end
  end

  def restore
    # Restore is a no-op for now since we don't have soft delete
    # This endpoint exists for future undo functionality
    box_id = params[:box_id]

    # For now, just return an error since we can't actually restore
    render json: { error: "Restore not available - item was permanently deleted" }, status: :unprocessable_entity
  end

  private

  def box_params
    params.permit(:name, :notes, :description, :parent_key).tap { |whitelist|
      whitelist[:parent_key] = nil if whitelist[:parent_key].present? && current_user.boxes.where(param_key: whitelist[:parent_key]).empty?
    }
  end

  def build_nested_export(boxes)
    root_boxes = boxes.where(parent_key: nil).ordered

    build_children = ->(parent) {
      {
        param_key: parent.param_key,
        name: parent.name,
        notes: parent.notes,
        description: parent.description,
        children: parent.contents.map { |child| build_children.call(child) }
      }
    }

    root_boxes.map { |box| build_children.call(box) }
  end

  def generate_csv_export(boxes)
    require "csv"

    CSV.generate(headers: true) do |csv|
      csv << %w[param_key name notes description hierarchy parent_key]

      boxes.ordered.each do |box|
        csv << [
          box.param_key,
          box.name,
          box.notes,
          box.description,
          box.hierarchy,
          box.parent_key
        ]
      end
    end
  end
end
