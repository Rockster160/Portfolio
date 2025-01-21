class Api::V1::BaseController < ApplicationController
  # before_action :doorkeeper_authorize!
  before_action { request.format ||= :json }
  before_action :authorize_user

  rescue_from ::ActiveRecord::RecordNotFound, with: :not_found_response

  def render_json(data)
    return serialize(data) if data.respond_to?(:serialize)

    json = data.except(:status)
    opts = data.slice(:status)

    render json: { data: json.as_json }, **opts
  end

  def serialize(data, opts={})
    errors = []

    case data
    when ::Hash, ::Array
    when ::ActiveRecord::Base
      errors = data.errors.full_messages
      data = data.serialize(opts)
    when ::ActiveRecord::Relation
      data = data.serialize(opts)
    end

    render(
      json: { data: data.as_json, errors: errors },
      status: errors.any? ? :unprocessable_entity : :ok,
    )
  end

  def authorize_user
    if current_user.nil?
      render_json error: "Please sign in before continuing.", status: :unauthorized
    elsif current_user.guest?
      render_json error: "Please finish setting up your account before continuing.", status: :unauthorized
    end
  end

  def authorize_admin
    if current_user.nil?
      render_json error: "Please sign in before continuing.", status: :unauthorized
    elsif !current_user.admin?
      render_json error: "Sorry, you do not have access to this page.", status: :unauthorized
    end
  end

  def not_found_response(exception)
    errors = ["#{controller_name.singularize.titleize} not found"]
    render json: { errors: errors }, status: :not_found
  end
end
