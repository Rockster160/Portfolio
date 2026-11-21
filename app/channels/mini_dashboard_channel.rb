# The Mac Mini dashboard's line to Portfolio (~/code/mini-dashboard), opened with Byte's
# secret: word that what it reads from GET /webhooks/byte/needs_you (NeedsYou) moved, so it
# fetches that when it changes instead of asking on a timer. Only that it moved goes out.
class MiniDashboardChannel < ApplicationCable::Channel
  def subscribed
    stream_for current_user
  end

  def self.changed(user)
    broadcast_to(user, { type: :changed }) if user
  end
end
