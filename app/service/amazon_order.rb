class AmazonOrder
  attr_accessor(
    :order_id,
    :item_id,
    :listed_name,
    :full_name,
    :name,
    :delivery_date,
    :time_range,
    :delivered,
    :email_ids,
    :errors,
    :just_added,
  )

  def self.all
    @@all ||= reload
  end

  def self.reload
    @@all = (MeCache.get(:amazon_deliveries) || []).map { |data| new(data) }
  end

  def self.save
    MeCache.set(:amazon_deliveries, serialize)
    clear
  end

  def self.clear
    @@all = nil
  end

  def self.broadcast
    clear # Get a fresh broadcast
    ActionCable.server.broadcast(:amz_updates_channel, serialize)
    clear # Clear for next
  end

  def self.legacy_serialize
    all.map(&:legacy_serialize)
  end

  def self.reparse(email_or_email_id)
    email = email_or_email_id.is_a?(Email) ? email_or_email_id : Email.find(email_or_email_id)
    AmazonEmailParser.parse(email)
  end

  def self.find(order_id, item_id=nil)
    all.find { |order|
      next unless order.order_id == order_id
      item_id.nil? || order.item_id == item_id
    }
  end

  def self.by_order(order_id)
    all.select { |order| order.order_id == order_id }
  end

  def self.find_or_create(order_id, item_id)
    find(order_id, item_id) || create(order_id: order_id, item_id: item_id)
  end

  def self.create(order_hash)
    new(order_hash.merge(just_added: true)).tap { |item| @@all << item }
  end

  def initialize(order_hash)
    @errors = []
    @email_ids = []
    @just_added = false # Gets overridden
    order_hash.each do |key, val|
      self.send("#{key}=".to_sym, val) if self.respond_to?(key)
    end
  end

  def reparse(email_id=nil)
    email_id ||= email_ids.last
    AmazonEmailParser.parse(Email.find(email_id))
  end

  def url
    "https://www.amazon.com/dp/#{item_id}"
  end

  def destroy
    @@all = AmazonOrder.all.select { |order| order.item_id != item_id }
    self
  end

  def error!(str)
    @errors ||= []
    @errors.push(str)
  end

  def legacy_serialize
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
