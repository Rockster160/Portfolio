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

  def initialize(args)
    set_all(args)
    self
  end

  def set_all(args)
    args.each do |k, v|
      self.send("#{k}=", v)
    end
    self
  end

  def mode=(new_mode)
    subscription.set_mode(self, new_mode)
  end

  def temp=(new_temp)
    subscription.set_temp(self, current_mode, new_temp)
  end

  def set_cool(new_cool)
    subscription.set_temp(self, :cool, new_cool)
  end

  def set_heat(new_heat)
    subscription.set_temp(self, :heat, new_heat)
  end

  def set_temp(temp_mode, new_temp)
    if temp_mode == :cool
      self.cool_set = new_temp
    else
      self.heat_set = new_temp
    end
  end

  def reload
    subscription.reload(self)
  end
end
