class FaeController < ApplicationController
  # Ordered monitor keys for the button row. Keyed off the listener rather
  # than the task id: `lib/scripts/fae_chore_buttons.rb` creates these in prod,
  # so the ids aren't knowable here but the monitor names are.
  #
  # Grouped by person — all four of his, then all four of hers. The row is
  # capped at 560px (four 120px buttons), so each group lands on its own line.
  BUTTON_MONITORS = [
    :"laundry-mine",
    :"food-mine",
    :"litter-mine",
    :"refill-litter-mine",
    :"laundry-hers",
    :"food-hers",
    :"litter-hers",
    :"refill-litter-hers",
  ].freeze

  before_action :authorize_user

  def show
    @list = current_user.ordered_lists.find_by(name: "Fae Chores")

    listeners = BUTTON_MONITORS.map { |monitor| "monitor::fae-btn-#{monitor}" }
    tasks = current_user.accessible_tasks.where(listener: listeners).index_by(&:listener)
    @tasks = listeners.filter_map { |listener| tasks[listener] }
  end
end
