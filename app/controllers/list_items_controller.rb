class ListItemsController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authorize_user_or_guest

  def show
    @list_item = current_list_items.with_deleted.find(params[:id])

    render json: @list_item
  end

  def edit
    @list_item = current_list_items.with_deleted.find(params[:id])
  end

  def create
    current_list = List.find(params[:list_id])
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
    success = new_item.update(create_params.merge(deleted_at: nil, sort_order: nil))

    return render json: { errors: "Cannot create item without a name." } unless success

    trigger(:added, new_item)

    if params[:as_json]
      render json: new_item
    else
      render template: "list_items/show", locals: { item: new_item }, layout: false
    end
  end

  def update
    current_list = List.find(params[:list_id])
    @existing_item = current_list_items.with_deleted.find_by(id: params[:id])
    @existing_item.update(list_item_params)

    trigger(:changed, @existing_item)

    render json: @existing_item
  end

  def destroy
    @list_item = ListItem.with_deleted.find(params[:id])

    if params[:really_destroy]
      @list_item.destroy
      trigger(:removed, @list_item)
      redirect_to list_path(@list_item.list)
    else
      @list_item.soft_destroy unless @list_item.permanent?
      head :no_content
    end
  end

  private

  def trigger(action, item)
    # added | changed | removed
    return if item.blank?

    ::Jil.trigger(current_user, :item, item.jil_serialize(action: action))
  end

  def current_list
    @current_list ||= current_user.lists.find_by(id: params[:list_id]) || current_user.lists.by_param(params[:list_id]).take!
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

    @current_item ||= current_list_items.find(params[:id] || name)
  end

  def list_item_params
    return {} if params[:list_item].blank?

    params.require(:list_item).permit(
      :name,
      :checked,
      :sort_order,
      :important,
      :permanent,
      :category,
      :schedule,
      schedule: [
        :interval,
        :hour,
        :minute,
        :type,
        :meridian,
        :timezone,
        {
          weekly:  [day: []],
          monthly: [
            :type,
            {
              week: (-1..31).map { |t| { t.to_s => [] } },
              day:  [],
            },
        ],
        },
      ],
    )
  end
end
