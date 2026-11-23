# The phones signed in to the Buddy app, and each one's settings: which
# features are on and their options, all set here so nothing has to be
# configured on the phone. Revoking one locks it out of every
# /api/ios endpoint at once.
class AppDevicesController < ApplicationController
  before_action :authorize_user
  before_action :authorize_admin, only: :install_link
  before_action :set_device, except: [:index, :install_link]

  def index
    order = Arel.sql("revoked_at IS NOT NULL, last_seen_at DESC NULLS LAST")
    @app_devices = current_user.app_devices.order(order)
    @this_device_id = cookies.signed[:app_device_id]
  end

  def show
    @this_device = @device.id == cookies.signed[:app_device_id]
  end

  def update
    @device.configure!(
      features:    params.key?(:features) ? Array(params[:features]).compact_blank : nil,
      preferences: params[:preferences].respond_to?(:permit!) ? params[:preferences].permit!.to_h : nil,
    )
    redirect_to app_device_path(@device), notice: "Saved"
  end

  # One of the phone's own tasks (a sync, a battery send), run from here.
  def run
    @device.run!(params[:task])
    redirect_to app_device_path(@device), notice: "Sent to #{@device.name}"
  rescue ArgumentError => e
    redirect_to app_device_path(@device), alert: e.message
  end

  def test_push
    result = @device.test_push!(params[:kind], user: current_user)
    message = result&.ok? ? "Test sent to #{@device.name}" : "Apple refused it: #{result&.reason || "no push token"}"
    redirect_to app_device_path(@device), (result&.ok? ? :notice : :alert) => message
  end

  # The one link the household is sent to install the app from.
  def install_link
    AppDevice.install_url = params[:install_url]
    redirect_to app_devices_path, notice: "Install link saved"
  rescue ArgumentError => e
    redirect_to app_devices_path, alert: e.message
  end

  def destroy
    @device.revoke!
    redirect_to app_devices_path, notice: "Signed that device out"
  end

  private

  def set_device
    @device = current_user.app_devices.find(params[:id])
  end
end
