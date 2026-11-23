# The Buddy app's login page. The app opens it in its web view and hands over
# what the phone is; a good password signs the web view in and issues the
# phone its own device token, passed to the app on the page rather than in a
# URL so it never lands in a log.
class AppSessionsController < ApplicationController
  DEVICE_FIELDS = [:name, :model, :os_version, :app_version, :timezone].freeze

  before_action :set_device_params

  def new
    @user = User.new
  end

  def create
    @user = User.attempt_login(params.dig(:user, :username).to_s, params.dig(:user, :password).to_s)
    if @user.nil? || @user.guest?
      @user = User.new(username: params.dig(:user, :username))
      @user.errors.add(:base, "Username and password combination not found.")
      return render(:new, status: :unprocessable_entity)
    end

    sign_in(@user)
    @device, @token = AppDevice.issue!(
      @user,
      name:         @device_params[:name].presence || "iPhone",
      platform:     :ios,
      model:        @device_params[:model],
      os_version:   @device_params[:os_version],
      app_version:  @device_params[:app_version],
      timezone:     @device_params[:timezone],
      last_seen_at: Time.current,
    )
    cookies.permanent.signed[:app_device_id] = { value: @device.id, domain: :all, tld_length: 2 }
    response.headers["Cache-Control"] = "no-store"
    render :signed_in
  end

  private

  def set_device_params
    @device_params = params.fetch(:device, {}).permit(*DEVICE_FIELDS).to_h.symbolize_keys
  end
end
