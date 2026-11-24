class UpdateActionStreak
  include Sidekiq::Worker

  # An event's streak follows from the one before it with the same name: the
  # same day keeps it, the next day adds one, and anything longer starts over.
  def self.length_after(previous, event)
    return 1 if previous.nil?

    Time.use_zone(event.user.timezone) {
      today = event.timestamp.in_time_zone.beginning_of_day
      yesterday = (event.timestamp - 1.day).in_time_zone.beginning_of_day
      next previous.streak_length if previous.timestamp >= today
      next previous.streak_length + 1 if previous.timestamp >= yesterday

      1
    }
  end

  def perform(event_id)
    # Removed before this ran (deleted, or merged into another), so there is
    # nothing left to count from.
    event = ActionEvent.find_by(id: event_id)
    return if event.nil?

    matching_events = ActionEvent.where(user_id: event.user_id).ilike(name: event.name)
    matching_events = matching_events.where.not(id: event.id)
    previous = matching_events.where(timestamp: ...event.timestamp).order(:timestamp).last

    if previous && previous.streak_length.nil?
      earliest_nil = matching_events.where(streak_length: nil).order(:timestamp).first
      return UpdateActionStreak.perform_async(earliest_nil.id)
    end

    # Each streak depends only on the one before it, so one that comes out as it
    # already was leaves every later one as it was too. Walking on regardless
    # turned a backfill of a thousand events into a job for every pair of them.
    length = self.class.length_after(previous, event)
    return if event.streak_length == length

    event.update(streak_length: length)
    following = matching_events.where("timestamp > ?", event.timestamp).order(:timestamp).first
    UpdateActionStreak.perform_async(following.id) if following.present?
  end
end
