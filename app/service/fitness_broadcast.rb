class FitnessBroadcast
  def self.call(event=nil)
    return broadcast if event.nil?

    broadcast_events = [
      :Pullups,
      :Workout,
      :Vitamins,
      :Water,
      :Teeth,
      :Shower,
      :Soda,
      :Wordle,
    ]

    return unless event.event_name.to_sym.in?(broadcast_events)

    broadcast
  end

  def self.broadcast
    fitness_data = ::CommandProposal::Services::Runner.execute(:fitness_data)

    ActionCable.server.broadcast "fitness_channel", fitness_data: fitness_data.result
  end
end
