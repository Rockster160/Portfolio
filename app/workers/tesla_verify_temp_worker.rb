class TeslaVerifyTempWorker
  include Sidekiq::Worker

  sidekiq_options retry: false

  MAX_ATTEMPTS = 3

  # `attempt` is bumped by each retry so we can't recurse forever when the
  # car refuses to converge on the target. Tesla.set_temp re-enqueues this
  # worker, so without a counter a stuck climate would Slack-spam + retry
  # every 5 seconds in a tight loop.
  def perform(temp_F, attempt=1)
    set_temp_c = Tesla.vehicle_data.dig(:climate_state, :driver_temp_setting)
    return if set_temp_c.nil? # no current reading — can't compare; give up quietly

    # Tesla returns temp in Celsius
    temp_C = ((temp_F.to_f - 32) * (5 / 9.to_f)).round(1)
    return if ((set_temp_c - 1)..(set_temp_c + 1)).cover?(temp_C)

    if attempt >= MAX_ATTEMPTS
      SlackNotifier.notify("Tesla temp still wrong after #{MAX_ATTEMPTS} attempts; giving up.")
      return
    end

    SlackNotifier.notify("Tesla lost temp. Trying again (attempt #{attempt + 1}/#{MAX_ATTEMPTS})...")
    # `skip_verify: true` so TeslaControl doesn't enqueue a fresh verify
    # chain at attempt=1 — we manage our own attempt counter here.
    TeslaControl.me.set_temp(temp_F, skip_verify: true)
    self.class.perform_in(5.seconds, temp_F, attempt + 1)
  end
end
