class JarvisController < ApplicationController
  skip_before_action :verify_authenticity_token

  def command
    render plain: Jarvis.command(current_user, params[:message])
  end
end
