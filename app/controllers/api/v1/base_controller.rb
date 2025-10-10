class Api::V1::BaseController < ApplicationController
  # before_action :doorkeeper_authorize!
  before_action { request.format ||= :json }
  before_action :authorize_user

  rescue_from ::ActiveRecord::RecordNotFound, with: :not_found_response

  def authorize_user
    if current_user.nil?
      render_json error: "Please sign in before continuing.", status: :unauthorized
    elsif current_user.guest?
      render_json error: "Please finish setting up your account before continuing.",
        status: :unauthorized
    end
  end

  def authorize_admin
    if current_user.nil?
      render_json error: "Please sign in before continuing.", status: :unauthorized
    elsif !current_user.admin?
      render_json error: "Sorry, you do not have access to this page.", status: :unauthorized
    end
  end

  def not_found_response(_exception)
    errors = ["#{controller_name.singularize.titleize} not found"]
    render json: { errors: errors }, status: :not_found
  end
end
