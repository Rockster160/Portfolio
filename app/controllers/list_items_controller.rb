class ListItemsController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authorize_user_or_guest

  def show
    @list = current_user.lists.find(params[:list_id])
    @list_item = @list.list_items.with_deleted.find(params[:id])

    render json: @list_item
  end

  def edit
    @list = current_user.lists.find(params[:list_id])
    @list_item = @list.list_items.with_deleted.find(params[:id])
  end

  def create
    @list = List.find(params[:list_id])
    create_params = list_item_params
    if create_params[:category].blank?
      create_params[:name].match(/\A\s*\[(.+)\]\s*([^(\[]+)\s*\z/m) { |m|
        category, name = m[1], m[2]
        next if name.blank?

        section = @list.sections.where_soft_name(category)
        if section.one?
          create_params[:section_id] = section.first.id
          create_params[:name] = name
        elsif category.present?
          create_params[:category] = category
          create_params[:name] = name
        end
      }
    end

    new_item = @list.list_items.by_name_then_update(create_params)
    return render json: { errors: "Cannot create item without a name." } unless new_item.persisted?

    ::Jil.trigger(current_user, :item, new_item.jil_serialize(action: :added)) # changed | removed

    if params[:as_json]
      render json: new_item
    else
      render template: "list_items/show", locals: { item: new_item }, layout: false
    end
  end

  def update
    @list = List.find(params[:list_id])
    @existing_item = @list.list_items.with_deleted.find_by(id: params[:id])
    @existing_item.update(list_item_params)

    ::Jil.trigger(current_user, :item, @existing_item.jil_serialize(action: :changed))

    render json: @existing_item
  end

  def destroy
    @list_item = ListItem.with_deleted.find(params[:id])

    if params[:really_destroy]
      @list_item.destroy
      ::Jil.trigger(current_user, :item, @existing_item.jil_serialize(action: :removed))
      redirect_to list_path(@list_item.list)
    else
      @list_item.soft_destroy unless @list_item.permanent?
      head :no_content
    end
  end

  private

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
