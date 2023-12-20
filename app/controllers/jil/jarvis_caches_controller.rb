class Jil::JarvisCachesController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authorize_user
  layout false

  def show
    @cache = current_user.jarvis_cache
  end

  def update
    @cache = current_user.jarvis_cache

    if @cache.update(params[:cache])
      # Probably should do a remote push
    else
    end
  end
end
