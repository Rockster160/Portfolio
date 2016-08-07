class WebhooksController < ApplicationController
  before_action :post_params

  def pokemon

  end

  private

  def post_params
    puts "#{params}"
  end

end
