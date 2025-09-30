class Api::V1::ListItemsController < Api::V1::BaseController
  skip_before_action :verify_authenticity_token
  before_action :authorize_user_or_guest

  def index
    items = current_list_items
    items = items.with_deleted if params[:with_deleted] == "true"

    serialize items
  end

  def show
    serialize current_item
  end

  def create
    create_params = list_item_params
    if create_params[:category].blank?
      create_params[:name].match(/\A\s*\[(.+)\]\s*([^(\[]+)\s*\z/m) { |m|
        category, name = m[1], m[2]
        next if name.blank?

        section = current_list.sections.where_soft_name(category)
        if section.one?
          create_params[:section_id] = section.first.id
          create_params[:name] = name
        elsif category.present?
          create_params[:category] = category
          create_params[:name] = name
        end
      }
    end
    new_item = current_item(:soft) || current_list_items.new
    new_item.update(create_params.merge(deleted_at: nil, sort_order: nil))

    ::Jil.trigger(current_user, :item, new_item.jil_serialize(action: :created))

    serialize new_item
  end

  def update
    current_item.update(list_item_params)
    ::Jil.trigger(current_user, :item, current_item.jil_serialize(action: :changed))

    serialize current_item
  end

  def destroy
    current_item.soft_destroy unless current_item.permanent?
    ::Jil.trigger(current_user, :item, current_item.jil_serialize(action: :removed))

    serialize current_item
  end

  private

  def current_list
    @list ||= current_user.lists.find_by(id: params[:list_id]) || current_user.lists.by_param(params[:list_id]).take!
  end

  def current_list_items
    @current_list_items ||= current_list.list_items.with_deleted
  end

  def current_item(mode=:hard)
    name = list_item_params[:name].presence || params[:name]
    @item = current_list_items.find_by(id: params[:id] || name)
    @item ||= current_list_items.by_formatted_name(name) if name.present?
    @item ||= current_list_items.by_formatted_name(params[:id])
    return @item if mode == :soft
    @item ||= current_list_items.find(params[:id] || name)
  end

  def list_item_params
    params.permit(
      :name,
      :checked,
      :category,
      :important,
      :permanent,
    )
  end
end
