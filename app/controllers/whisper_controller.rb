class WhisperController < ApplicationController
  CHELSEA_ID = 58128
  EVE_ID = 4

  OWNER_IDS = [1, CHELSEA_ID].freeze
  CARETAKER_IDS = [EVE_ID].freeze

  before_action :authorize_user
  before_action :authorize_whisper_viewer, only: :show
  before_action :authorize_whisper_owner, only: :log_vomit

  def show
    return unless whisper_owner?

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
      413, # Fae Probiotic
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

  def whisper_owner?
    OWNER_IDS.include?(current_user&.id)
  end
  helper_method :whisper_owner?

  def whisper_viewer?
    whisper_owner? || CARETAKER_IDS.include?(current_user&.id)
  end

  def authorize_whisper_viewer
    head :forbidden unless whisper_viewer?
  end

  def authorize_whisper_owner
    head :forbidden unless whisper_owner?
  end
end
