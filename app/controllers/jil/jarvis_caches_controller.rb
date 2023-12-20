class Jil::JarvisCachesController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authorize_user
  layout false

  def show
    @cache = current_user.jarvis_cache
  end

  def update
    @cache = current_user.jarvis_cache

    if @cache.update(data: params[:cache])
      render json: {}, status: :ok
    else
      render json: {}, status: :bad_request
    end
  end
end
