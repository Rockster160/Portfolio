class AmzUpdatesChannel < ApplicationCable::Channel
  def subscribed
    stream_from "amz_updates_channel"
  end

  def change(data)
    json = data.deep_symbolize_keys
    order = AmazonOrder.find(json[:order_id], json[:item_id])

    if json[:merge]
      # `2+4` in home.js: fold the source item into the target, keeping the
      # target's name/basic info but adopting the source's tracking/shipping
      # data so future carrier updates land on the target row.
      source = AmazonOrder.find(json[:from_order_id], json[:from_item_id])
      if order && source && !(order.order_id == source.order_id && order.item_id == source.item_id)
        order.merge!(source)
      end
    elsif json[:remove]
      order.destroy
    else
      name = json[:add] || json[:rename]
      return if name.blank?

      sub, datetime = ::Jarvis::Times.extract_time(name, context: :future)
      name = name.gsub(sub, "") unless sub.nil?

      order ||= AmazonOrder.create(carrier: :manual) if json.key?(:add)
      order.name = name.squish if name.present?
      order.delivery_date = datetime if datetime.present?

      order.name ||= "[NONAME]"
      order.delivery_date ||= Date.current

      # Persist the (possibly user-edited) name to the per-ASIN catalog so the
      # next order of the same SKU reuses it without another GPT call.
      AmazonItemCatalog.set(order.item_id, name: order.name) if order.name.present?
    end

    AmazonOrder.save
    AmazonOrder.broadcast
  end

  def request(_)
    AmazonOrder.broadcast
  end
end
