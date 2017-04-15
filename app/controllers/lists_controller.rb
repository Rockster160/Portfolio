class ListsController < ApplicationController

  def index
    @list = List.where(name: "list").first
    render :show
  end

  def show
    @list = List.select { |l| l.name.parameterize == params[:list_name] }.first
    raise ActionController::RoutingError.new('Not Found') unless @list.present?
  end

end
