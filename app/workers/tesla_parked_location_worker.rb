class TeslaParkedLocationWorker
  include Sidekiq::Worker

  sidekiq_options retry: false

  # Enqueued twice on a shift into Park with a leg open. The first asks the car
  # where it is — it is awake, having just been driven, so this never wakes it —
  # and settles the arrival on that position. The second runs once the wait for
  # a fresh position has run out, for a car that went quiet after parking and
  # sent no push of its own to settle it.
  # rubocop:disable Style/OptionalBooleanParameter -- Sidekiq args are positional
  def perform(poll=true)
    TeslaCommand.broadcast(TeslaControl.me.vehicle_data) if poll
    TeslaTelemetry.settle_travel
  end
  # rubocop:enable Style/OptionalBooleanParameter
end
