class WebhooksController < ApplicationController
  before_action :post_params

  def pokemon

  end

  private

  def post_params
    Rails.logger.warn "#{params}"
  end

end
