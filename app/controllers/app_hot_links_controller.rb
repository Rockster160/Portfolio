# The person's hot links, one list for every phone and widget.
class AppHotLinksController < ApplicationController
  before_action :authorize_user

  def show
    @hot_links = Array(current_user.hot_links)
    @catalog = {
      tasks:    current_user.accessible_tasks.active.enabled.order(:name).reject(&:function?),
      routines: current_user.buddy_routines.where(enabled: true).order(:position),
      lists:    current_user.lists.order(:name),
    }
  end

  # The page saves as it's edited, so the reply is the saved list, each link
  # with the id a new one was given. A refusal leaves what was typed in place.
  def update
    links = params[:hot_links].respond_to?(:permit!) ? params[:hot_links].permit!.to_h.values : []
    AppDevices::HotLinks.save!(current_user, links)
    render json: { hot_links: current_user.hot_links }
  rescue ArgumentError => e
    render json: { message: e.message }, status: :unprocessable_entity
  end
end
