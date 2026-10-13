# Restates everybody's anchors against the calendar and their hand-scheduled
# triggers, so anything hung off one is holding a current answer. See
# AnchorFeeder for what each key means.
#
# Only people who own an anchor are walked: the key is the subscription, so an
# account with none has nothing to state. Feeding is a no-op in steady state -
# AnchorOccurrence only announces a move when the time actually changed - so
# this is cheap to run often and is what makes a moved interview reach the
# reminder hanging off it within the five minutes.
class AnchorFeedWorker
  include Sidekiq::Worker

  sidekiq_options retry: false

  def perform
    User.where(id: Anchor.select(:user_id).distinct).find_each { |user| feed(user) }
  end

  def feed(user)
    AnchorFeeder.call(user)
  rescue StandardError => e
    Rails.logger.error("[AnchorFeedWorker] user=#{user.id} #{e.class}: #{e.message}")
    raise unless Rails.env.production?
  end
end
