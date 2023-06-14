class FitnessBroadcast
  def self.call(event=nil)
    return broadcast if event.nil?

    broadcast_events = [
      :Pullups,
      :Workout,
      :Z,
      :Vitamins,
      :Fluox,
      :Escitalopram,
      :Buspirone,
      :Methylphenidate,
      :Water,
      :Teeth,
      :Shower,
      :Treat,
      :Soda,
      :Wordle,
    ]

    return unless event.event_name.to_sym.in?(broadcast_events)

    broadcast
  end

  def self.broadcast
    fitness_data = ::CommandProposal::Services::Runner.execute(:fitness_data)
    # ActionEvents should have a service/API that can be used to gather this data publically

    ActionCable.server.broadcast :fitness_channel, { fitness_data: fitness_data.result }
  rescue ActiveRecord::RecordNotFound
      # no-op - Command doesn't exist locally
  end
end
