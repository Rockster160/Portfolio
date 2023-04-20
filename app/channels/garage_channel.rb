class GarageChannel < ApplicationCable::Channel
  def subscribed
    stream_from "garage_channel"
  end

  def unsubscribed
    ActionCable.server.broadcast("garage_channel", { data: "refreshGarage" })
  end

  def request
    ActionCable.server.broadcast("garage_channel", { msg: "getGarage" })
  end

  def control(data)
    GarageCommand.command(data["direction"])
  end

  # :ping garage data: { garageState: :open }
  # :ping garage data: :refreshGarage
  # ActionCable.server.broadcast("garage_channel", { data: { garageState: :closed } })
  # open
  # ActionCable.server.broadcast("garage_channel", { msg: "openGarage" })
  # close
  # ActionCable.server.broadcast("garage_channel", { msg: "closeGarage" })
  # toggle
  # ActionCable.server.broadcast("garage_channel", { msg: "toggleGarage" })
  # get
  # ActionCable.server.broadcast("garage_channel", { msg: "getGarage" })
  def message(data)
    ActionCable.server.broadcast("garage_channel", { data: data })
  end
end
