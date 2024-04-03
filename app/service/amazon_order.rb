class AmazonOrder
  attr_accessor :id, :name, :delivery_date, :time_range, :delivered, :errors

  def self.all
    @@all = deliveries_cache.map { |id, data|
      new(data.merge(order_id: id))
    }
  end

  def self.deliveries_cache
    (DataStorage[:amazon_deliveries] || {})
  end

  def self.find(id)
    all.find { |order| id && order.id == id } || new(id: id)
  end

  def serialize
    all.map(&:to_h)
  end

  def initialize(order_hash)
    order_hash.each do |key, val|
      self.send("#{key}=".to_sym, val) if self.respond_to?(key)
    end
  end

  def save
    DataStorage[:amazon_deliveries] = deliveries_cache.merge(id => serialize)
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
      errors: errors || [],
    }
  end
end
