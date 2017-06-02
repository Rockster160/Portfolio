class ListsController < ApplicationController
  before_action :authorize_user

  def index
    @lists = current_user.lists.order(:created_at)
  end

  def edit
    @list = current_user.lists.find(params[:id])
  end

  def update
    @list = current_user.lists.find(params[:id])

    if @list.update(list_params)
      redirect_to list_path(@list)
    else
      render :edit
    end
  end

  def show
    if params[:id].to_i.to_s == params[:id]
      @list = current_user.lists.find(params[:id])
    else
      @list = current_user.lists.select { |l| l.name.parameterize == params[:id] }.first
    end

    raise ActionController::RoutingError.new('Not Found') unless @list.present?
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
    @list = current_user.lists.find(params[:id])

    if @list.owned_by_user?(current_user) && @list.destroy
      redirect_to lists_path
    else
      redirect_to edit_list_path(@list)
    end
  end

  def users
    @list = current_user.lists.find(params[:id])
  end

  def receive_update
    @list = List.find(params[:id])

    new_order = params[:list_item_order] || []
    new_order.each_with_index do |list_item_id, idx|
      list_item = @list.list_items.find_by_id(list_item_id)
      next unless list_item.present?
      list_item.update(sort_order: idx, do_not_broadcast: true)
    end
    @list.broadcast!
  end

  private

  def list_params
    params.require(:list).permit(:name, :description)
  end

end
