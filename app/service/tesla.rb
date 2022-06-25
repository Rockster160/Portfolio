class Tesla
  attr_accessor :id, :controller

  # Allows calling methods directly from the class rather than `Tesla.new.start` -> `Tesla.start`
  def self.method_missing(method, *args, &block)
    car = new
    car.send(method)
    car
  end

  def initialize(controller=nil)
    @controller = controller || TeslaControl.new(self)
    @id = @controller.vehicle_id
  end

  def data
    controller.vehicle_data
  end

  def on
    controller.start_car
  end

  def off
    controller.off_car
  end

  def pop_boot
    controller.pop_boot
  end

  def pop_frunk
    controller.pop_frunk
  end

  def set_temp(temp_F)
    controller.start_car
    controller.set_temp(temp_F)
  end

  def heat_driver
    controller.heat_driver
  end

  def heat_passenger
    controller.heat_passenger
  end
end
