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

      # Pull an optional inline metadata block off the end first, e.g.
      #   add Computer Desk on Aug 7 { url: "https://…" }
      # so its contents (URLs full of digits) can't confuse time parsing.
      meta, name = parse_metadata(name)

      sub, datetime = ::Jarvis::Times.extract_time(name, context: :future)
      name = name.gsub(sub, "") unless sub.nil?

      order ||= AmazonOrder.create(carrier: :manual) if json.key?(:add)
      return if order.nil?

      order.name = name.squish if name.present?
      order.delivery_date = datetime if datetime.present?
      order.custom_url = meta[:url] if meta[:url].present?
      order.source = meta[:source] if meta[:source].present?
      order.tracking_number = meta[:tracking_number] if meta[:tracking_number].present?

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

  private

  # Extracts a trailing `{ key: "value", … }` block from a command string.
  # Returns [meta_hash, remaining_text]. Lenient — unquoted keys and quoted or
  # bare values — since it's typed by hand in the dashboard, not strict JSON.
  # Only recognized keys (url / source / tracking_number) are acted on upstream.
  def parse_metadata(text)
    match = text.match(/\{(.+)\}/m)
    return [{}, text] if match.nil?

    meta = {}
    match[1].scan(/(\w+)\s*:\s*(?:"([^"]*)"|'([^']*)'|([^,}]+))/) { |key, dq, sq, bare|
      val = (dq || sq || bare).to_s.strip
      meta[key.to_sym] = val unless val.empty?
    }

    [meta, text.sub(match[0], " ").squish]
  end
end
