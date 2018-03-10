class ListItemsController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authorize_user

  def show
    @list = current_user.lists.find(params[:list_id])
    @list_item = @list.list_items.find(params[:id])

    render json: @list_item
  end

  def edit
    @list = current_user.lists.find(params[:list_id])
    @list_item = @list.list_items.find(params[:id])
  end

  def create
    @list = List.find(params[:list_id])
    new_item = @list.list_items.by_name_then_update(list_item_params)

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

    render json: @existing_item
  end

  def destroy
    @list_item = ListItem.with_deleted.find(params[:id])
    @list_item.destroy unless @list_item.permanent?

    head :no_content
  end

  private

  def list_item_params
    return {} unless params[:list_item].present?
    params.require(:list_item).permit(:name, :checked, :sort_order, :important, :permanent, :schedule, :category)
  end

end
