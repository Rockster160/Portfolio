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

  # The settings page saves each switch as it's flipped: one feature, or the
  # options that changed. The reply is what was saved, which is what the page
  # shows, so a switch iOS won't allow yet flips back.
  def update
    features = params.key?(:features) ? Array(params[:features]).compact_blank : nil
    if params.key?(:feature)
      key = params[:feature].to_s
      on = ActiveModel::Type::Boolean.new.cast(params[:on])
      features = on ? @device.features | [key] : @device.features - [key]
    end
    preferences = params[:preferences]
    preferences = preferences.respond_to?(:permit!) ? preferences.permit!.to_h : nil
    @device.configure!(features: features, preferences: preferences)
    respond_to do |format|
      format.json {
        render json: { features: @device.features, preferences: @device.all_preferences }
      }
      format.html { redirect_to app_device_path(@device), notice: "Saved" }
    end
  end

  # One of the phone's own tasks (a sync, a battery send), run from here.
  def run
    @device.run!(params[:task])
    reply("Sent to #{@device.name}")
  rescue ArgumentError => e
    reply(e.message, ok: false)
  end

  def test_push
    result = @device.test_push!(params[:kind])
    return reply("Sent to #{@device.name}") if result&.ok?

    reply("Not sent: #{refusal(result&.reason)}", ok: false)
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

  def reply(message, ok: true)
    respond_to do |format|
      format.json { render json: { message: message }, status: ok ? :ok : :unprocessable_entity }
      format.html { redirect_to app_device_path(@device), (ok ? :notice : :alert) => message }
    end
  end

  def refusal(reason)
    case reason&.to_sym
    when nil, :NoToken then "#{@device.name} hasn't registered for push yet"
    when :NotConfigured then "the server has no APNs key for this build"
    else "Apple refused it (#{reason})"
    end
  end
end
