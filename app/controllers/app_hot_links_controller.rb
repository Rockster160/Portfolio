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

  def update
    links = params[:hot_links].respond_to?(:permit!) ? params[:hot_links].permit!.to_h.values : []
    AppDevices::HotLinks.save!(current_user, links)
    redirect_to app_hot_links_path, notice: "Saved"
  rescue ArgumentError => e
    redirect_to app_hot_links_path, alert: e.message
  end
end
