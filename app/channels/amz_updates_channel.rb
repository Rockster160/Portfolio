class AmzUpdatesChannel < ApplicationCable::Channel
  def subscribed
    stream_from "amz_updates_channel"
  end

  def change(data)
    order = AmazonOrder.find(data["id"])

    if data["remove"]
      order.destroy
    elsif data["rename"]
      order.name = data["rename"]
      order.save
      # TODO: Allow changing the time, too
      # TODO: Allow adding new items for tracking
    # elsif data["add"]
    #   msg = data["add"].gsub(/^add /, "")
    #   sub, time = ::Jarvis::Times.extract_time(msg, context: :future)
    #   name = msg.gsub(sub, "")
    #   deliveries[name] = {
    #     name: name,
    #     delivery: time&.strftime("%Y-%m-%-d") || "[ERROR]",
    #   }
    end

    ActionCable.server.broadcast(:amz_updates_channel, AmazonOrder.serialize)
  end

  def request(_)
    ActionCable.server.broadcast(:amz_updates_channel, DataStorage[:amazon_deliveries])
  end
end
