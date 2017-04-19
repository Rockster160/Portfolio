# == Schema Information
#
# Table name: list_items
#
#  id         :integer          not null, primary key
#  name       :string(255)
#  list_id    :integer
#  created_at :datetime
#  updated_at :datetime
#

class ListItemsController < ApplicationController

  def create
    @list = List.find(params[:list_id])

    new_item = @list.list_items.create(list_item_params)

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
    params.require(:list_item).permit(:name)
  end

end
