class JilChannel < ApplicationCable::Channel
  def subscribed
    stream_from "jil_channel"
  end
end
