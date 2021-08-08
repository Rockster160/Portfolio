class ActionEventsController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authorize_user

  def create
    ActionEvent.create(action_event_params.merge(user: current_user))

    head :ok
  end

  private

  def action_event_params
    params.slice(:event, :timestamp, :notes)
  end
end
