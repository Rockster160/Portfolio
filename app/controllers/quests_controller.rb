# Quest boards: a game's daily objectives, tapped off like chores on the
# Today view, one board per game. The phone keeps each board in localStorage
# and every tap is local; this controller holds a copy of that blob, names and
# lists the boards, and runs the hooks an item can fire.
class QuestsController < ApplicationController
  include HomeScreenInstall

  before_action :authorize_user, except: [:manifest, :icon]
  before_action :set_board, only: [:show, :update, :destroy, :state, :save]
  before_action :set_installed_board, only: [:manifest, :icon]

  def index
    @boards = current_user.quest_boards.order(:created_at)
  end

  def show; end

  def create
    board = current_user.quest_boards.create(name: params[:name].to_s.strip)
    return redirect_to(quests_path) unless board.persisted?

    redirect_to quest_board_path(board)
  end

  # Any of the name and the home-screen icon; a field left out stays as it
  # was. `icon_png` is the canvas's data URL, or blank to go back to the
  # default icon.
  def update
    attrs = {}
    attrs[:name] = params[:name].to_s.strip if params.key?(:name)
    if params.key?(:icon_png)
      attrs[:icon] = params[:icon].to_s.presence
      attrs[:icon_color] = params[:icon_color].to_s.presence
      attrs[:icon_data_url] = params[:icon_png].to_s
    end
    return head(:unprocessable_entity) unless @board.update(attrs)

    render json: {
      name:       @board.name,
      icon:       @board.icon,
      icon_color: @board.icon_color,
      icon_url:   helpers.home_screen_icon_url(@board),
    }
  end

  # GET /quests/:id/manifest.webmanifest — the board's own install manifest,
  # so a board added to a home screen opens on itself, named after itself,
  # wearing its chosen icon.
  def manifest
    render_install_manifest(
      @board,
      id:          "quest-board-#{@board.id}",
      path:        quest_board_path(@board),
      icon_src:    helpers.home_screen_icon_url(@board),
      description: "Quests: #{@board.name}",
    )
  end

  # GET /quests/:id/icon.png — the PNG drawn in Board settings.
  def icon
    send_home_screen_icon(@board)
  end

  def destroy
    @board.destroy
    render json: { ok: true }
  end

  def state
    render json: { data: @board.data, rev: @board.rev }
  end

  # Last write wins, by the time the phone stamped on its own copy. A device
  # holding an older board than the stored one is handed the stored one back
  # rather than allowed to roll it back.
  def save
    incoming = request.request_parameters["data"]
    return head(:unprocessable_entity) unless incoming.is_a?(Hash)

    if stamp(incoming) < stamp(@board.data)
      return render(json: { data: @board.data, rev: @board.rev }, status: :conflict)
    end

    @board.data = incoming
    @board.rev += 1
    return head(:unprocessable_entity) unless @board.save

    render json: { rev: @board.rev }
  end

  # kind :event creates an ActionEvent (with every listener it would wake from
  # any other source) and answers its id, which is what undo hands back.
  # kind :trigger fires a named Jil trigger; its undo is the same trigger with
  # `action: :undo`, since a trigger has nothing to delete.
  def hook
    payload = request.request_parameters
    data = payload["data"].is_a?(Hash) ? payload["data"] : {}

    case payload["kind"].to_s.to_sym
    when :event
      event = current_user.action_events.create(
        name:  payload["name"].to_s,
        notes: payload["notes"].presence,
        data:  data.presence,
      )
      return head(:unprocessable_entity) unless event.persisted?

      notify(event, :added)
      render json: { event_id: event.id }
    when :trigger
      scope = payload["trigger"].to_s.strip
      return head(:unprocessable_entity) if scope.blank?

      jil_trigger(scope, data)
      render json: { ok: true }
    else
      head :unprocessable_entity
    end
  end

  def unhook
    event = current_user.action_events.find_by(id: params[:id])
    return render(json: { ok: true }) if event.nil?

    event.destroy
    notify(event, :removed)
    ::RecentEventsBroadcast.call
    render json: { ok: true }
  end

  private

  def set_board
    @board = current_user.quest_boards.find(params[:id])
  end

  def set_installed_board
    @board = find_installed(QuestBoard)
    head(:not_found) if @board.nil?
  end

  def stamp(data)
    data.is_a?(Hash) ? data["updatedAt"].to_i : 0
  end

  def notify(event, action)
    ::ActionEventNotifier.notify(current_user, event, action, auth: jil_auth_type, auth_id: jil_auth_id)
  end
end
