class WhisperController < ApplicationController
  CHELSEA_ID = 58_128
  EVE_ID = 4

  OWNER_IDS = [1, CHELSEA_ID].freeze
  CARETAKER_IDS = [EVE_ID].freeze

  # NOTE! When adding one, share the task with Chelsea — otherwise it renders
  # blank on her iPad and never receives its broadcast.
  BUTTON_MONITORS = [
    :fed,
    :water,
    :"nap-toggle",
    :"home-toggle",
    :sleep,
    :outside,
    :quiet,
    :"nap-sound",
  ].freeze

  before_action :authorize_user
  before_action :authorize_whisper_viewer, only: :show
  before_action :authorize_whisper_owner, only: :log_vomit

  def show
    return unless whisper_owner?

    @list = current_user.ordered_lists.find(360)

    listeners = BUTTON_MONITORS.map { |monitor| "monitor::whisper-btn-#{monitor}" }
    tasks = current_user.accessible_tasks.where(listener: listeners).index_by(&:listener)
    @tasks = listeners.filter_map { |listener| tasks[listener] }
  end

  def log_vomit
    timestamp = params[:timestamp].presence&.then { |t| ::Time.zone.parse(t) } || ::Time.current

    User.me.action_events.create!(
      name:      "Whisper",
      notes:     "Vomit",
      data:      { notes: params[:notes].to_s },
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
