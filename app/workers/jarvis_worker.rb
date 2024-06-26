class JarvisWorker
  include Sidekiq::Worker

  def perform(user_id, msg)
    parsed = BetterJsonSerializer.load(msg)

    # puts "\e[35m[LOGIT] | JarvisWorker(#{user_id})parsed:[#{parsed.class}]#{parsed}\e[0m"
    case parsed
    when String then ::Jarvis.command(User.find(user_id), parsed)
    when BetterJson, Hash
      event_data = parsed[:event]
      if event_data[:user_id].present? && event_data[:type].present?
        ::Jarvis.trigger_async(event_data[:user_id], event_data[:type], event_data.except(:type, :user_id))
        # ::Jarvis.trigger(
        #   event_data[:type],
        #   { input_vars: { "Event Data": event_data.except(:type, :user_id) } },
        #   scope: { user_id: event_data[:user_id] }
        # )
      end
    else
      # puts "\e[35m[LOGIT] | What is it? parsed:[#{parsed.class}]#{parsed}\e[0m"
    end

    ::Jarvis::Schedule.cleanup
  end

  def traveling_to_current?(event_data)
    # if task travel, if task end with -tt, -home, -travel
    #  if car currently at location traveling to
    #  OR car is currently driving
    return false unless event_data[:type].to_sym == :travel
    return false unless event_data[:uid].match?(/\-(tt|home|travel)$/)

    book = AddressBook.new(User.me)
    return false if book.blank?

    # How do we get the location that's being traveled to?
    # Maybe we just check for the current location in the "take me to" event
    # This should only check if the car is currently driving
    destination = [0, 0]

    book.distance(book.current_loc, destination)
  end
end
