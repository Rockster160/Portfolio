# == Schema Information
#
# Table name: lists
#
#  id         :integer          not null, primary key
#  name       :string(255)
#  created_at :datetime
#  updated_at :datetime
#

class ListsController < ApplicationController

  def index
    @list = List.where(name: "list").first
    render :show
  end

  def update
    @list = List.find(params[:id])

    new_order = params[:list_item_order] || []
    new_order.each_with_index do |list_item_id, idx|
      puts "#{list_item_id}: #{idx}"
      list_item = @list.list_items.find(list_item_id)
      list_item.update(sort_order: idx, do_not_broadcast: true)
    end
    @list.broadcast!
  end

  def show
    @list = List.select { |l| l.name.parameterize == params[:list_name] }.first
    raise ActionController::RoutingError.new('Not Found') unless @list.present?
  end

end
