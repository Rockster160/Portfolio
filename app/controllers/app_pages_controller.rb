# The Buddy app's own pages: the command console and queue, the quick prompt
# and the share sheet. They're site pages like any other; what lives only on
# the phone (the queue, what's being shared) the page reads from the app.
class AppPagesController < ApplicationController
  before_action :authorize_user
  before_action :set_device

  def commands; end

  # Opened by a hot link or widget that asks a question before it sends: the
  # answer, after its prefix, goes as a command or a Buddy message.
  def compose
    @send_as = params[:send_as].to_s == "command" ? :command : :buddy
    @prefix = params[:prefix].to_s
    @question = params[:placeholder].presence
    @inline = ActiveModel::Type::Boolean.new.cast(params[:inline]) || @send_as == :command
    @data = params[:data].presence
  end

  def share; end

  def settings
    return redirect_to(app_devices_path) if @device.nil?

    redirect_to app_device_path(@device)
  end

  private

  # The phone this web view belongs to, remembered when the app signed it in,
  # or the only phone there is.
  def set_device
    devices = current_user.app_devices.active
    @device = devices.find_by(id: cookies.signed[:app_device_id])
    @device ||= devices.first if devices.one?
  end
end
