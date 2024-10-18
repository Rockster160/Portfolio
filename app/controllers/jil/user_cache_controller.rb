class Jil::UserCacheController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authorize_user
  layout false, only: :show

  def index
    @caches = current_user.caches.order(updated_at: :desc)
  end

  def show
    @cache = current_user.caches.by(params[:id])
  end

  def update
    @cache = current_user.caches.by(params[:id])

    if @cache.update(wrap_data: params[:cache])
      render json: {}, status: :ok
    else
      render json: {}, status: :bad_request
    end
  end
end
