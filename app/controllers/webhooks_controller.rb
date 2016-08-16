class WebhooksController < ApplicationController
  before_action :post_params

  private

  def post_params
    Rails.logger.warn "#{params}"
  end

end
