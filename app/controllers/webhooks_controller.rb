class WebhooksController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :post_params

  def jenkins
    head 200
  end

  def post
    head 200
  end

  def email
    Email.receive(request)
    head :no_content
  end

  def command
    return head :no_content unless user_signed_in?

    List.find_and_modify(current_user, params[:command])
  end

  private

  def post_params
    Rails.logger.warn "#{params}"
  end

end
