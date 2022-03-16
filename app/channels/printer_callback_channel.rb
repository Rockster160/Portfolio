class PrinterCallbackChannel < ApplicationCable::Channel
  def subscribed
    stream_from "printer_callback_channel"
  end
end
