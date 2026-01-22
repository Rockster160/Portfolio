class InventoryChannel < ApplicationCable::Channel
  def subscribed
    stream_from "inventory_#{current_user.id}_channel"
  end

  def unsubscribed
    # Any cleanup needed when channel is unsubscribed
  end

  def receive(data)
    data = data.deep_symbolize_keys!

    if data[:get].present?
      # Request full inventory data for a specific box
      box = current_user.boxes.find_by(param_key: data[:get])
      broadcast_box!(box) if box
    elsif data[:refresh].present?
      # Request refresh of all top-level boxes
      current_user.boxes.where(parent_key: nil).find_each do |box|
        broadcast_box!(box)
      end
    end
  end

  private

  def broadcast_box!(box)
    ActionCable.server.broadcast(
      "inventory_#{current_user.id}_channel",
      { box: box.serialize, timestamp: Time.current.to_i },
    )
  end
end
