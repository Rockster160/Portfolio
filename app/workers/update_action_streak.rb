class UpdateActionStreak
  include Sidekiq::Worker

  def perform(event_id)
    event = ActionEvent.find(event_id)
    matching_events = ActionEvent
      .where(user_id: event.user_id)
      .ilike(event_name: event.event_name)
      .where.not(id: event.id)
    previous = matching_events.where("timestamp < ?", event.timestamp).order(:timestamp).last

    if previous.nil?
      event.update(streak_length: 1)
    elsif previous.streak_length.nil?
      earliest_nil = matching_events.where(streak_length: nil).order(:timestamp).first
      return UpdateActionStreak.perform_async(earliest_nil.id)
    else
      Time.use_zone(event.user.timezone) do
        yesterday = (event.timestamp - 1.day).in_time_zone.beginning_of_day
        today = event.timestamp.in_time_zone.beginning_of_day
        if previous.timestamp > today # Happened Today
          event.update(streak_length: previous.streak_length) # Same streak length - don't increase
        elsif previous.timestamp > yesterday # Happened yesterday
          event.update(streak_length: previous.streak_length + 1) # Streak +1
        elsif previous.timestamp < yesterday # Happened BEFORE yesterday
          event.update(streak_length: 1) # Reset streak
        else
          ::SlackNotifier.err("Exception hit: No condition found current(#{event.timestamp}) previous(#{previous.timestamp})")
        end
      end
    end

    following = matching_events.where("timestamp > ?", event.timestamp).order(:timestamp).first
    UpdateActionStreak.perform_async(following.id) if following.present?
  end
end
