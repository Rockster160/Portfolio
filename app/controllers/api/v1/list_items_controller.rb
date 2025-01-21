class Api::V1::ListItemsController < Api::V1::BaseController
  skip_before_action :verify_authenticity_token
  before_action :authorize_user_or_guest

  def index
    serialize current_list.list_items.serialize
  end

  def show
    serialize current_item
  end

  def create
    new_item = current_list.list_items.create(list_item_params)

    serialize new_item
  end

  def update
    current_item.update(list_item_params)

    serialize current_item
  end

  def destroy
    current_item.soft_destroy unless current_item.permanent?

    serialize current_item
  end

  private

  def current_list
    @list = current_user.lists.find_by(id: params[:list_id]) || current_user.lists.by_param(params[:list_id]).take!
  end

  def current_item
    @item = current_list.list_items.find_by(id: params[:id])
    @item ||= current_list.list_items.by_formatted_name(params[:id])
    @item ||= current_list.list_items.find(params[:id])
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
