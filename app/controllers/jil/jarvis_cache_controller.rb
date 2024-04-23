class Jil::JarvisCacheController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authorize_user_or_guest
  layout false

  def show
    @cache = current_user.jarvis_caches.by(params[:id])
  end

  def update
    @cache = current_user.jarvis_caches.by(params[:id])

    if @cache.update(wrap_data: params[:cache])
      render json: {}, status: :ok
    else
      render json: {}, status: :bad_request
    end
  end
end
