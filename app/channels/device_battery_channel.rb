class DeviceBatteryChannel < ApplicationCable::Channel
  def subscribed
    stream_for current_user
  end

  def request(_)
    self.class.broadcast_to(current_user, current_user.caches.get(:battery) || {})
  end
end
