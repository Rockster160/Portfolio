# A waiting form with something live on it - a duration still running - kept
# current: its refresh step once a minute, scheduled one tick at a time, so it
# stops the moment the form stops waiting or a day has passed. See
# Buddy::FormAction#ticking?.
class BuddyFormTickWorker
  include Sidekiq::Worker

  sidekiq_options queue: :low, retry: false

  def perform(action_id)
    action = ByteAction.find_by(id: action_id)
    return unless Buddy::FormAction.ticking?(action)

    Buddy::FormAction.tick!(action)
    Buddy::FormAction.schedule_tick!(action.reload)
  end
end
