class ListItemsController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authorize_user_or_guest

  def show
    @list_item = current_list_items.find(params[:id])

    render json: @list_item
  end

  def edit
    @list_item = current_list_items.find(params[:id])
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
    @existing_item = current_list_items.find_by(id: params[:id])
    was_deleted = @existing_item&.deleted?
    @existing_item.update(list_item_params)

    trigger(transition(was_deleted, @existing_item), @existing_item)

    render json: @existing_item
  end

  def destroy
    @list_item = current_list_items.find(params[:id])

    if params[:really_destroy]
      @list_item.destroy
      trigger(:removed, @list_item)
      redirect_to list_path(@list_item.list)
    else
      # `soft_destroy` answers falsy when the item was already gone, so a
      # repeat DELETE says nothing rather than announcing a removal twice.
      trigger(:removed, @list_item) if !@list_item.permanent? && @list_item.soft_destroy
      head :no_content
    end
  end

  private

  def trigger(action, item)
    # added | changed | removed
    return if item.blank?

    jil_trigger(:item, item.jil_serialize(action: action))
  end

  # What actually happened to the item, which is not always what the ROUTE says.
  #
  # Checking a box in the app is a PUT carrying `checked: true`, and that
  # soft-deletes the item - the same act, on the same column, as the API's
  # DELETE and as Jil's `List.remove`, both of which report `removed`. Calling
  # it `changed` meant a listener could watch an item arrive and never once
  # hear it leave, with no second signal anywhere to make up for it.
  #
  # Unticking is the mirror: the item is back on the list, which is `added`,
  # matching what `ListItem.toggle` has always fired for the same transition.
  def transition(was_deleted, item)
    return :changed if item.blank? || was_deleted == item.deleted?

    item.deleted? ? :removed : :added
  end

  def current_list
    @list ||= @current_list ||= (
      current_user.lists.find_by(id: params[:list_id]) ||
        current_user.lists.by_param(params[:list_id]).take!
    )
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
      :section_id,
    )
  end
end
