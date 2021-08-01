class ActionEventsController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authorize_user

  def create
    ActionEvent.create(user: current_user, event_name: params[:event])

    head :ok
  end
end
