class ListsController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authorize_user_or_guest, :color_scheme
  before_action :set_list, only: [:edit, :update, :show, :destroy, :users, :modify_from_message]

  def index
    @lists = current_user.ordered_lists

    respond_to do |format|
      format.js { render json: @lists.serialize }
      format.html
    end
  end

  def show
    raise ActionController::RoutingError, "Not Found" if @list.blank?

    @tasks = current_user.tasks.find(params[:t].split(/[,|]/) || []) if params[:t].present?

    respond_to do |format|
      format.js { render json: @list.serialize }
      format.html
    end
  end

  def new
    @list = List.new
  end

  def reorder
    params[:list_ids].each_with_index do |list_id, idx|
      current_user.user_lists.find_by(list_id: list_id).update(
        sort_order:       idx,
        do_not_broadcast: true,
      )
    end

    redirect_to lists_path
  end

  def create
    @list = List.create(list_params)

    if @list.persisted?
      current_user.user_lists.create(
        list_id: @list.id, is_owner: true,
        default: params[:default] == "true"
      )
      trigger(:added, @list)
      redirect_to @list
    else
      render :new
    end
  end

  def update
    if params[:get]
      @list.broadcast!
      trigger(:changed, @list)
      return head :ok
    end
    if params[:sort]
      @list.sort_items!(params[:sort], params[:order])
      trigger(:changed, @list)
      return head :ok
    end

    if @list.update(list_params)
      @user_list&.update(default: params[:default] == "true") if params[:default].present?
      trigger(:changed, @list)
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

  def destroy
    if @list.owned_by_user?(current_user) && @list.destroy
      trigger(:removed, @list)
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

  def trigger(action, list)
    # added | changed | removed
    return if list.blank?

    ::Jil.trigger(current_user, :list, list.with_jil_attrs(action: action))
  end

  def reorder_list
    # ordered = [
    #   {type: :section, id: 1, items: [
    #     {type: :item, id: 321},
    #     {type: :item, id: 223},
    #     {type: :item, id: 12},
    #   ]},
    #   {type: :item, id: 123},
    #   {type: :item, id: 124},
    #   {type: :section, id: 2, items: [
    #     {type: :item, id: 18},
    #     {type: :item, id: 20},
    #     {type: :item, id: 89},
    #   ]},
    #   {type: :item, id: 126},
    # ]
    objects = params[:ordered].presence&.map { |h| h.permit!.to_unsafe_h } || []

    counter = -1
    objects.reverse.each do |obj_data|
      object = (
        if obj_data[:type].to_sym == :section
          @list.sections.find_by(id: obj_data[:id])
        elsif obj_data[:type].to_sym == :item
          @list.list_items.with_deleted.find_by(id: obj_data[:id])
        end
      )
      next if object.blank?

      object.section_id = nil if obj_data[:type].to_sym == :item
      object.update(sort_order: counter += 1, do_not_broadcast: true)

      next unless obj_data[:type].to_sym == :section

      (obj_data[:items] || []).reverse.each do |item_data|
        item = @list.list_items.with_deleted.find_by(id: item_data[:id])
        next if item.blank?

        item.section_id = obj_data[:id]
        item.update(sort_order: counter += 1, do_not_broadcast: true)
      end
    end
  end

  def set_list
    @list = current_user.lists.find_by(id: params[:id]) || current_user.lists.by_param(params[:id]).take
    @user_list = current_user.user_lists.find_by(list: @list)

    return if @list.present?
    return store_and_login if guest_account?

    redirect_to lists_path, alert: "You do not have permission to view this list."
  end

  def color_scheme
    session[:color_scheme] = params[:style] if params[:style].present?
  end

  def list_params
    if params[:list].present?
      params.require(:list).permit(
        :name, :description, :important, :show_deleted, :default,
        :message, :add, :remove
      ).tap { |whitelist|
        whitelist[:add] ||= params[:add] if params[:add].present?
        whitelist[:remove] ||= params[:remove] if params[:remove].present?
        whitelist[:message] ||= params[:message] if params[:message].present?
      }
    else
      params.permit(:message, :add, :remove)
      # params[:message].present? ? { message: params[:message] } : {}
    end
  end
end
