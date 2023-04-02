class Tesla
  attr_accessor :id, :controller

  # Allows calling methods directly from the class rather than `Tesla.new.start` -> `Tesla.start`
  def self.method_missing(method, *args, &block)
    new.send(method)
  end

  def initialize(controller=nil)
    @controller = controller || TeslaControl.new(self)
    @id = @controller.vehicle_id
  end

  delegate(
    :vehicle_data,
    :loc,
    :start_car,
    :off_car,
    :honk,
    :navigate,
    :defrost,
    :doors,
    :windows,
    :pop_boot,
    :pop_frunk,
    :heat_driver,
    :heat_passenger,
    to: :controller
  )

  def set_temp(temp_F)
    controller.start_car
    controller.set_temp(temp_F)
  end
end
