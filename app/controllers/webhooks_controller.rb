class WebhooksController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :post_params

  def jenkins
    head 200
  end

  private

  def post_params
    Rails.logger.warn "#{params}"
  end

end
