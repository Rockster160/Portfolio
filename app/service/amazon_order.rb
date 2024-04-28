class AmazonOrder
  attr_accessor(
    :order_id,
    :item_id,
    :listed_name,
    :full_name,
    :element, # Not serialized, but provides a reference to the doc.element
    :name,
    :delivery_date,
    :time_range,
    :delivered,
    :email_ids,
    :errors,
    :just_added,
    :url,
  )

  def self.all
    @@all ||= (DataStorage[:amazon_deliveries] || {}).map { |order_id, data| new(data) }
  end

  def self.serialize
    all.map(&:serialize)
  end

  def self.broadcast
    ActionCable.server.broadcast(:amz_updates_channel, serialize)
  end

  def self.find(order_id, item_id=nil)
    all.find { |order|
      next unless order.order_id == order_id
      item_id.nil? || order.item_id == item_id
    }
  end

  def self.find_or_create(order_id, item_id)
    find(order_id, item_id) || create(order_id: order_id, item_id: item_id)
  end

  def self.create(order_hash)
    new(order_hash.merge(just_added: true)).tap { |item| @@all << item }
  end

  def self.save
    DataStorage[:amazon_deliveries] = serialize
  end

  def initialize(order_hash)
    @errors = []
    @email_ids = []
    @just_added = false # Gets overridden
    order_hash.each do |key, val|
      self.send("#{key}=".to_sym, val) if self.respond_to?(key)
    end
  end

  def url
    "https://www.amazon.com/dp/#{item_id}"
  end

  # def save
  #   AmazonOrder.deliveries_cache.merge!(order_id => serialize)
  #   @@all = nil
  # end

  def destroy
    AmazonOrder.deliveries_cache.except!(order_id)
    @@all = nil
  end

  def error!(str)
    @errors ||= []
    @errors.push(str)
  end

  def serialize
    {
      order_id: order_id,
      item_id: item_id,
      listed_name: listed_name,
      full_name: full_name,
      name: name,
      delivery_date: delivery_date,
      time_range: time_range,
      delivered: delivered,
      email_ids: email_ids,
      errors: errors,
    }
  end
end
