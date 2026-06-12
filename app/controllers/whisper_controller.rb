class WhisperController < ApplicationController
  CHELSEA_ID = 58128

  before_action :authorize_user
  before_action :authorize_whisper_user, only: :log_vomit

  def show
    @list = current_user.ordered_lists.find(360)
    # @list.users << chels

    task_ids = [
      220, # Fed
      221, # Nap Toggle
      230, # Gone Toggle
      225, # Sleep
      275, # Outside Toggle
      # TODO: Replace with new task IDs after running prodExec whisper_new_buttons.rb
      311, # Quiet Btn
      312, # Nap Sound Btn
      # NOTE! When adding new tasks, ensure they are shared!
    ]
    # chels = User.find(58128)
    # task_ids.each { SharedTask.find_or_create_by(user: chels, task_id: _1) }
    @tasks = current_user.accessible_tasks.where(id: task_ids).sort_by { |t| task_ids.index(t.id) }
  end

  def log_vomit
    timestamp = params[:timestamp].presence&.then { |t| ::Time.zone.parse(t) } || ::Time.current

    User.me.action_events.create!(
      name: "Whisper",
      notes: "Vomit",
      data: { notes: params[:notes].to_s },
      timestamp: timestamp,
    )

    head :ok
  end

  private

  def authorize_whisper_user
    allowed_ids = [User.me.id, CHELSEA_ID]
    head :forbidden unless allowed_ids.include?(current_user&.id)
  end
end
