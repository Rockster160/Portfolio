class FaeController < ApplicationController
  BUTTON_MONITORS = [
    :"laundry-hers",
    :"food-hers",
    :"litter-hers",
    :"refill-litter-hers",
    :"laundry-mine",
    :"food-mine",
    :"litter-mine",
    :"refill-litter-mine",
  ].freeze

  before_action :authorize_user

  def show
    @list = current_user.ordered_lists.find_by(name: "Fae Chores")

    listeners = BUTTON_MONITORS.map { |monitor| "monitor::fae-btn-#{monitor}" }
    tasks = current_user.accessible_tasks.where(listener: listeners).index_by(&:listener)
    @tasks = listeners.filter_map { |listener| tasks[listener] }
  end
end
