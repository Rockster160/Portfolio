class GoogleNestDevice
  attr_accessor(
    :subscription,
    :key,
    :name,
    :humidity,
    :current_mode,
    :current_temp,
    :hvac,
    :heat_set,
    :cool_set,
  )

  # Allows calling methods directly from the class rather than `GoogleNestDevice.new.start` -> `GoogleNestDevice.start`
  def self.method_missing(method, *args, &block)
    nest = new
    nest.send(method)
    nest
  end

  def initialize(subscription=nil, args={})
    @subscription = subscription || GoogleNestControl.new
    set_all(args)
    self
  end

  def set_all(args)
    args&.each do |k, v|
      self.instance_variable_set("@#{k}".to_sym, v)
    end
    self
  end

  def to_json
    {
      key:          @key,
      name:         @name,
      humidity:     @humidity,
      current_mode: @current_mode,
      current_temp: @current_temp,
      hvac:         @hvac,
      heat_set:     @heat_set,
      cool_set:     @cool_set,
    }
  end

  def reload
    subscription.reload(self)
    self
  end

  def mode=(new_mode)
    subscription.set_mode(self, new_mode)
  end

  def temp=(new_temp)
    subscription.set_temp(self, new_temp)
  end

  def set_cool(new_cool)
    subscription.set_mode(self, :cool) unless current_mode == :cool
    subscription.set_temp(self, new_cool)
  end

  def set_heat(new_heat)
    subscription.set_mode(self, :heat) unless current_mode == :heat
    subscription.set_temp(self, new_heat)
  end

  def set_temp(temp_mode, new_temp)
    if temp_mode == :cool
      self.cool_set = new_temp
    else
      self.heat_set = new_temp
    end
  end
end
