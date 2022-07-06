class GarageChannel < ApplicationCable::Channel
  def subscribed
    stream_from "garage_channel"
  end

  def request
    ActionCable.server.broadcast("garage_channel", { msg: "getGarage" })
  end

  def control(data)
    ActionCable.server.broadcast("garage_channel", { msg: "#{data['direction']}Garage" })
  end

  def message(data)
    # open
    # ActionCable.server.broadcast("garage_channel", { msg: "openGarage" })
    # close
    # ActionCable.server.broadcast("garage_channel", { msg: "closeGarage" })
    # toggle
    # ActionCable.server.broadcast("garage_channel", { msg: "toggleGarage" })
    # get
    # ActionCable.server.broadcast("garage_channel", { msg: "getGarage" })
    ActionCable.server.broadcast("garage_channel", { data: data })
  end
end
