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
    elsif data["add"]
      msg = data["add"].gsub(/^add /, "")
      sub, time = ::Jarvis::Times.extract_time(msg, context: :future)
      name = msg.gsub(sub, "")
      deliveries[name] = {
        name: name,
        delivery: time&.strftime("%Y-%m-%-d") || "[ERROR]",
      }
    end

    DataStorage[:amazon_deliveries] = deliveries

    ActionCable.server.broadcast "amz_updates_channel", deliveries
  end

  def request(_)
    ActionCable.server.broadcast "amz_updates_channel", DataStorage[:amazon_deliveries]
  end
end
