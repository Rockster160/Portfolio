class ListsController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authorize_user
  before_action :set_list, only: [:edit, :update, :show, :destroy, :users, :modify_from_message]

  def index
    @lists = current_user.ordered_lists

    respond_to do |format|
      format.js { render json: @lists.map(&:jsonify) }
      format.html
    end
  end

  def reorder
    params[:list_ids].each_with_index do |list_id, idx|
      current_user.user_lists.find_by(list_id: list_id).update(sort_order: idx)
    end

    redirect_to lists_path
  end

  def modify_from_message
    response_message = @list.modify_from_message(params[:message])

    respond_to do |format|
      format.json { render json: @list.jsonify }
    end
  end

  def update
    if @list.update(list_params)
      redirect_to list_path(@list)
    else
      render :edit
    end
  end

  def show
    raise ActionController::RoutingError.new('Not Found') unless @list.present?

    respond_to do |format|
      format.js { render json: @list.jsonify }
      format.html
    end
  end

  def new
    @list = List.new
  end

  def create
    @list = List.create(list_params)

    if @list.persisted?
      current_user.user_lists.create(list_id: @list.id, is_owner: true)
      redirect_to @list
    else
      render :new
    end
  end

  def destroy
    if @list.owned_by_user?(current_user) && @list.destroy
      redirect_to lists_path
    else
      redirect_to edit_list_path(@list)
    end
  end

  def receive_update
    @list = List.find(params[:id])

    new_order = params[:list_item_order] || []
    new_order.each_with_index do |list_item_id, idx|
      list_item = @list.list_items.find_by(id: list_item_id)
      next unless list_item.present?
      list_item.update(sort_order: idx, do_not_broadcast: true)
    end
    @list.broadcast!
  end

  private

  def set_list
    @list = current_user.lists.find_by(id: params[:id]) || current_user.lists.select { |list| list.name.parameterize == params[:id] }.first
  end

  def list_params
    params.require(:list).permit(:name, :description)
  end

end
