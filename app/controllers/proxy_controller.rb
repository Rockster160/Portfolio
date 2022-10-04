class ProxyController < ApplicationController
  before_action :authorize_admin
  # skip_before_action :verify_authenticity_token

  def proxy
    respond_to do |format|
      format.json { render json: ProxyRequest.execute(**params.to_unsafe_h) }
    end
  end
end
