class FaeController < ApplicationController
  BUTTON_TASK_IDS = [410, 411, 412, 413, 414, 415, 417].freeze

  before_action :authorize_user

  def show
    @list = current_user.ordered_lists.find_by(name: "Fae Chores")

    @tasks = current_user.accessible_tasks
      .where(id: BUTTON_TASK_IDS)
      .sort_by { |t| BUTTON_TASK_IDS.index(t.id) }
  end
end
