class GarageChannel < ApplicationCable::Channel
  def subscribed
    stream_from "garage_channel"
  end

  def unsubscribed
    ActionCable.server.broadcast("garage_channel", { msg: "refreshGarage" })
  end

  def request
    ActionCable.server.broadcast("garage_channel", { msg: "getGarage" })
  end

  def control(data)
    data_dir = data["direction"]
    direction = :toggle if data_dir.match?(/(toggle|garage)/)
    direction = :open if data_dir.match?(/(open)/)
    direction = :close if data_dir.match?(/(close)/)
    direction ||= :toggle
    ActionCable.server.broadcast("garage_channel", { msg: "#{direction}Garage" })
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
