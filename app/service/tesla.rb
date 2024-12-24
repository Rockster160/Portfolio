class Tesla
  attr_accessor :id, :controller

  # Allows calling methods directly from the class rather than `Tesla.new.start` -> `Tesla.start`
  def self.method_missing(method, *args, &block)
    (@instance ||= new).send(method, *args)
  end

  def method_missing(method, *args, &block)
    @controller.send(method, *args, &block)
  end

  def initialize(controller=nil)
    @controller = controller || TeslaControl.me
    @id = @controller.vin
  end

  def set_temp(temp_F)
    controller.start_car
    controller.set_temp(temp_F)
  end

  # :vehicle_data
  # :cached_vehicle_data
  # :loc
  # :start_car
  # :off_car
  # :honk
  # :navigate
  # :defrost
  # :doors
  # :windows
  # :pop_boot
  # :pop_frunk
  # :heat_driver
  # :heat_passenger
end
