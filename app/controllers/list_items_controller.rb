class ListItemsController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authorize_user

  def create
    @list = List.find(params[:list_id])

    new_item = @list.list_items.find_or_create_by(list_item_params)

    if params[:as_json]
      render json: new_item
    else
      render template: "list_items/show", locals: { item: new_item }, layout: false
    end
  end

  def destroy
    @list_item = ListItem.find(params[:id])

    @list_item.destroy
    head :no_content
  end

  private

  def list_item_params
    params.require(:list_item).permit(:name, :sort_order)
  end

end
