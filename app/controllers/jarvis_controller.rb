class JarvisController < ApplicationController
  skip_before_action :verify_authenticity_token, raise: false

  def command
    render plain: Jarvis.command(current_user, params[:message])
  end
end
