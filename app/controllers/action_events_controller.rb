class ActionEventsController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authorize_user

  def create
    event = ActionEvent.create(action_event_params.merge(user: current_user))

    if event.persisted?
      head :ok
    else
      SlackNotifier.notify(event.errors.full_messages.join("\n"))
      head :unprocessable_entity
    end
  end

  private

  def action_event_params
    params.to_unsafe_h.slice(:event_name, :timestamp, :notes)
  end
end
