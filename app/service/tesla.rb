class Tesla
  attr_accessor :id, :controller

  def initialize(controller=nil)
    @controller = controller || TeslaControl.new(self)
    @id = @controller.vehicle_id
  end

  def data
    controller.vehicle_data
  end

  def start
    controller.start_car
  end

  def pop_boot
    controller.pop_boot
  end

  def pop_frunk
    controller.pop_frunk
  end

  def set_temp(temp_F)
    controller.set_temp(temp_F)
  end

  def heat_driver
    controller.heat_driver
  end

  def heat_passenger
    controller.heat_passenger
  end
end
