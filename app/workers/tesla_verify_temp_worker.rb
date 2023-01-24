class TeslaVerifyTempWorker
  include Sidekiq::Worker
  sidekiq_options retry: false

  def perform(temp_F)
    set_temp_c = Tesla.vehicle_data.dig(:climate_state, :driver_temp_setting)
    # Tesla returns temp in Celsius
    temp_C = ((temp_F.to_f - 32) * (5/9.to_f)).round(1)

    if !((set_temp_c-1)..(set_temp_c+1)).cover?(temp_C)
      SlackNotifier.notify("Tesla lost temp. Trying again...")
      Tesla.set_temp(temp_F)
    end
  end
end
