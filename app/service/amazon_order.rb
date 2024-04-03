class AmazonOrder
  attr_accessor :id, :name, :delivery_date, :time_range, :delivered, :email_ids, :errors, :new

  def self.all
    @@all = deliveries_cache.map { |id, data|
      new(data.merge(id: id))
    }
  end

  def self.deliveries_cache
    (DataStorage[:amazon_deliveries] || {})
  end

  def self.find(id)
    all.find { |order| id && order.id == id } || new(id: id, new: true)
  end

  def self.serialize
    all.each_with_object({}) { |order, obj| obj[order.id] = order.serialize }
  end

  def initialize(order_hash)
    @errors = []
    @email_ids = []
    @new = false
    order_hash.each do |key, val|
      self.send("#{key}=".to_sym, val) if self.respond_to?(key)
    end
  end

  def save
    DataStorage[:amazon_deliveries] = AmazonOrder.deliveries_cache.merge(id => serialize)
  end

  def destroy
    DataStorage[:amazon_deliveries] = AmazonOrder.deliveries_cache.except(id)
  end

  def error!(str)
    @errors ||= []
    @errors.push(str)
  end

  def serialize
    {
      order_id: id,
      name: name,
      delivery_date: delivery_date,
      time_range: time_range,
      delivered: delivered,
      email_ids: email_ids,
      errors: errors,
    }
  end
end
