class PingsController < ApplicationController
  # skip_before_action :verify_authenticity_token

  def create
    ActionCable.server.broadcast("ping_channel", params.to_unsafe_h.except(:controller, :action, :ping))

    head :created
  end
end
