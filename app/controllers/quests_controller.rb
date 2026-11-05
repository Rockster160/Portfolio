# The quest board: a game's daily objectives, tapped off like chores on the
# Today view. The phone keeps the whole board in localStorage and every tap is
# local; this controller only holds a copy of that blob and runs the hooks an
# item can fire.
class QuestsController < ApplicationController
  before_action :authorize_user

  def show; end

  def state
    board = QuestBoard.for(current_user)
    render json: { data: board.data, rev: board.rev }
  end

  # Last write wins, by the time the phone stamped on its own copy. A device
  # holding an older board than the stored one is handed the stored one back
  # rather than allowed to roll it back.
  def save
    board = QuestBoard.for(current_user)
    incoming = request.request_parameters["data"]
    return head(:unprocessable_entity) unless incoming.is_a?(Hash)

    if stamp(incoming) < stamp(board.data)
      return render(json: { data: board.data, rev: board.rev }, status: :conflict)
    end

    board.data = incoming
    board.rev += 1
    return head(:unprocessable_entity) unless board.save

    render json: { rev: board.rev }
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

  def stamp(data)
    data.is_a?(Hash) ? data["updatedAt"].to_i : 0
  end

  def notify(event, action)
    ::ActionEventNotifier.notify(current_user, event, action, auth: jil_auth_type, auth_id: jil_auth_id)
  end
end
