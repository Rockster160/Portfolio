class WhisperController < ApplicationController
  before_action :authorize_user

  def show
    @list = current_user.ordered_lists.find(360)
    # @list.users << chels

    task_ids = [
      220, # Fed
      221, # Nap Toggle
      230, # Gone Toggle
      225, # Sleep
      # NOTE! When adding new tasks, ensure they are shared!
    ]
    # task_ids.each { SharedTask.find_or_create_by(user: chels, task_id: _1) }
    @tasks = current_user.accessible_tasks.where(id: task_ids).sort_by { |t| task_ids.index(t.id) }
  end
end
