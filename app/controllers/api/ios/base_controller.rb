# Everything the phone app calls. Authenticated by the device token alone, so
# a revoked phone is locked out of every endpoint at once.
class Api::Ios::BaseController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action { request.format = :json }
  before_action :authorize_device

  rescue_from ::ActiveRecord::RecordNotFound, with: :not_found
  rescue_from ::ArgumentError, with: :unprocessable

  private

  def current_device
    current_user
    @current_device
  end

  def authorize_device
    if current_device.nil?
      return render(json: { error: "Not signed in on this device." }, status: :unauthorized)
    end

    current_device.seen!
  end

  def not_found(_exception=nil)
    render json: { error: "Not found." }, status: :not_found
  end

  def unprocessable(exception)
    render json: { error: exception.message }, status: :unprocessable_entity
  end

  def absolute(path)
    return if path.blank?
    return path if path.to_s.match?(%r{\Ahttps?://})

    "#{request.base_url}#{"/" unless path.to_s.start_with?("/")}#{path}"
  end

  # Byte lives on its own subdomain.
  def byte_url(path="/")
    host = request.host.sub(/\A(www|byte)\./, "")
    port = request.port.in?([80, 443]) ? "" : ":#{request.port}"
    "#{request.scheme}://byte.#{host}#{port}#{path}"
  end
end
