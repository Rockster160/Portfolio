class AmzUpdatesChannel < ApplicationCable::Channel
  def subscribed
    stream_from "amz_updates_channel"
  end

  def change(data)
    json = data.deep_symbolize_keys
    order = AmazonOrder.find(json[:order_id], json[:item_id])

    if json[:remove]
      order.destroy
    else
      name = json[:add] || json[:rename]
      return if name.blank?

      sub, datetime = ::Jarvis::Times.extract_time(name, context: :future)
      name = name.gsub(sub, "") unless sub.nil?

      order ||= AmazonOrder.create if json.key?(:add)
      order.name = name.squish if name.present?
      order.delivery_date = datetime if datetime.present?

      order.name ||= "[NONAME]"
      order.delivery_date ||= Date.current
    end

    AmazonOrder.save
    AmazonOrder.broadcast
  end

  def request(_)
    AmazonOrder.broadcast
  end
end
