class NfcChannel < ApplicationCable::Channel
  def subscribed
    stream_from "nfc_channel"
  end

  def unsubscribed
    # Any cleanup needed when channel is unsubscribed
  end
end
