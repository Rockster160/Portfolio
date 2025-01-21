class Api::V1::ListsController < Api::V1::BaseController
  skip_before_action :verify_authenticity_token
  before_action :authorize_user_or_guest

  def index
    @lists = current_user.ordered_lists

    serialize @lists, with_deleted: params[:with_deleted] == "true"
  end

  def show
    serialize current_list, with_deleted: params[:with_deleted] == "true"
  end

  def reorder
    params[:list_ids].each_with_index do |list_id, idx|
      current_user.user_lists.find_by(list_id: list_id).update(sort_order: idx)
    end

    serialize current_user.ordered_lists
  end

  def order_items
    @list = current_list

    params[:item_ids].each_with_index do |id, index|
      @list.list_items.find(id).update(position: index)
    end

    serialize @list
  end

  def create
    new_list = current_user.lists.create(list_item_params)
    new_list.persisted? && current_user.user_lists.create(list_id: new_list.id, is_owner: true, default: params[:default] == "true")

    serialize new_list
  end

  def update
    @list = current_list

    if @list.update(list_params)
      # @user_list&.update(default: params[:default] == "true") if params[:default].present?
    end

    serialize @list
  end

  private

  def current_list
    @list ||= current_user.lists.find_by(id: params[:id]) || current_user.lists.by_param(params[:id]).take!
  end

  def list_params
    params.permit(:name, :description, :important, :show_deleted, :default)
  end
end
