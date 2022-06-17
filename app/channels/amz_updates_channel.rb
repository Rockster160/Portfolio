class AmzUpdatesChannel < ApplicationCable::Channel
  def subscribed
    stream_from "amz_updates_channel"
  end

  def change(data)
    deliveries = DataStorage[:amazon_deliveries].with_indifferent_access || {}
    if data["remove"]
      deliveries.delete(data["id"])
    elsif data["rename"]
      order = deliveries[data["id"]]
      order[:name] = data["rename"]
    end

    DataStorage[:amazon_deliveries] = deliveries

    ActionCable.server.broadcast "amz_updates_channel", deliveries
  end

  def request(_)
    ActionCable.server.broadcast "amz_updates_channel", DataStorage[:amazon_deliveries]
  end
end
