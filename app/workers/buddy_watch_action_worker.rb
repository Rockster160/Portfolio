# The gap in "trigger whisper-quiet ten seconds after the doggy door".
#
# A delay can't be a sleep: the trigger that matched is on a request or a
# worker that other watches are still queued behind, and holding it hostage for
# a quiet-hours light would stall every one of them. So the wait is a scheduled
# job, and this is what lands on the other side of it.
#
# Re-checks the watch on the way in. Ten seconds is short, but "cancel that"
# arriving inside the window is exactly when someone means it most, and a
# cancelled watch that fires anyway is worse than one that fires late.
class BuddyWatchActionWorker
  include Sidekiq::Worker

  sidekiq_options queue: :default, retry: 1

  def perform(watch_id)
    watch = BuddyWatch.find_by(id: watch_id)
    return if watch.nil? || watch.cancelled_at.present?

    Buddy::WatchMatcher.run_action_now!(watch)
  rescue StandardError => e
    Buddy::Errors.report(
      section:   "buddy_watch_action",
      exception: e,
      user:      watch&.user,
      extra:     { watch_id: watch_id },
    )
  end
end
