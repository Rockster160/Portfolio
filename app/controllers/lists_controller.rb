class ListsController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authorize_user, :color_scheme
  before_action :set_list, only: [:edit, :update, :show, :destroy, :users, :modify_from_message]

  def index
    @lists = current_user.ordered_lists

    respond_to do |format|
      format.js { render json: @lists.serialize }
      format.html
    end
  end

  def reorder
    params[:list_ids].each_with_index do |list_id, idx|
      current_user.user_lists.find_by(list_id: list_id).update(sort_order: idx, do_not_broadcast: true)
    end

    redirect_to lists_path
  end

  def update
    if params[:get]
      @list.broadcast!
      return head :ok
    end
    if params[:sort]
      @list.sort_items!(params[:sort], params[:order])
      return head :ok
    end

    if @list.update(list_params)
      @user_list&.update(default: params[:default] == "true") if params[:default].present?
      respond_to do |format|
        format.js { render json: @list.serialize }
        format.html { redirect_to list_path(@list) }
      end
    else
      respond_to do |format|
        format.js { render json: { errors: @list.errors.full_messages }, status: :forbidden }
        format.html { render :edit }
      end
    end
  end

  def show
    raise ActionController::RoutingError.new('Not Found') unless @list.present?

    respond_to do |format|
      format.js { render json: @list.serialize }
      format.html
    end
  end

  def new
    @list = List.new
  end

  def create
    @list = List.create(list_params)

    if @list.persisted?
      current_user.user_lists.create(list_id: @list.id, is_owner: true, default: params[:default] == "true")
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

    reorder_list
    @list.broadcast!
  end

  private

  def reorder_list
    return if params[:list_item_order].blank?

    new_order = params[:list_item_order]
    @list.list_items.with_deleted.update_all(sort_order: nil)
    new_order.reverse.each_with_index do |list_item_id, idx|
      list_item = @list.list_items.with_deleted.find_by(id: list_item_id)
      next unless list_item.present?
      list_item.update(sort_order: idx, do_not_broadcast: true)
    end
  end

  def set_list
    @list = current_user.lists.find_by(id: params[:id]) || current_user.lists.select { |list| list.name.parameterize == params[:id] }.first
    @user_list = current_user.user_lists.find_by(list: @list)

    return if @list.present?
    redirect_to lists_path, alert: "You do not have permission to view this list."
  end

  def color_scheme
    session[:color_scheme] = params[:style] if params[:style].present?
  end

  def list_params
    if params[:list].present?
      params.require(:list).permit(:name, :description, :important, :show_deleted, :default, :message, :add, :remove).tap do |whitelist|
        whitelist[:add] ||= params[:add] if params[:add].present?
        whitelist[:remove] ||= params[:remove] if params[:remove].present?
        whitelist[:message] ||= params[:message] if params[:message].present?
      end
    else
      params.permit(:message, :add, :remove)
      # params[:message].present? ? { message: params[:message] } : {}
    end
  end

end
