class PlaygroundController < ApplicationController
  def show
    @project = PlaygroundProject.find(params[:id])
    raise ActionController::RoutingError, "Not Found" if @project.nil?
  end
end
